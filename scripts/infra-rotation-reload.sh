#!/usr/bin/env bash
#
# infra-rotation-reload.sh
#
# Automated rotation-reload loop for a Quantum-L9 service:
#   1. Re-issue a fresh Infisical Universal Auth client secret (out-of-band,
#      never touches Terraform state).
#   2. Write the new 3 bootstrap vars to the service's EnvironmentFile (chmod 600).
#   3. Send SIGHUP to the running service so installSighupReload() fires and
#      refreshSecrets() re-auths with the new secret without a process restart.
#   4. Wait for the Infisical overlap window, then revoke the old secret.
#
# Called by rotation-reload.service. All config comes from env (EnvironmentFile
# /etc/infisical-admin/rotation.env, chmod 600, root:root).
#
# Required env:
#   INFISICAL_ADMIN_CLIENT_ID        terraform-admin identity client id
#   INFISICAL_ADMIN_CLIENT_SECRET    terraform-admin identity client secret
#   ROTATION_IDENTITY_ID             identity_id from terraform output identities
#   ROTATION_PROJECT_ID              project_id from terraform output identities
#   ROTATION_SERVICE_NAME            systemd service unit name (e.g. seo-bot)
#   ROTATION_ENV_FILE                path to EnvironmentFile (e.g. /etc/seo-bot/infisical.env)
#
# Optional env:
#   INFISICAL_HOST                   default https://app.infisical.com
#   ROTATION_OVERLAP_SECONDS         seconds to wait before revoking old secret (default 300)
#   ROTATION_OLD_SECRET_ID           set internally; do not set externally
#
# Requires: curl, jq, systemctl
set -euo pipefail

HOST="${INFISICAL_HOST:-https://app.infisical.com}"
OVERLAP="${ROTATION_OVERLAP_SECONDS:-300}"

: "${INFISICAL_ADMIN_CLIENT_ID:?set INFISICAL_ADMIN_CLIENT_ID}"
: "${INFISICAL_ADMIN_CLIENT_SECRET:?set INFISICAL_ADMIN_CLIENT_SECRET}"
: "${ROTATION_IDENTITY_ID:?set ROTATION_IDENTITY_ID}"
: "${ROTATION_PROJECT_ID:?set ROTATION_PROJECT_ID}"
: "${ROTATION_SERVICE_NAME:?set ROTATION_SERVICE_NAME}"
: "${ROTATION_ENV_FILE:?set ROTATION_ENV_FILE}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemctl is required" >&2; exit 1; }

log() { echo "[rotation-reload] $*"; }

# ── Step 1: Authenticate as terraform-admin ──────────────────────────────────
log "Authenticating as terraform-admin..."
TOKEN="$(curl -fsS -X POST "$HOST/api/v1/auth/universal-auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"clientId\":\"$INFISICAL_ADMIN_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_ADMIN_CLIENT_SECRET\"}" \
  | jq -r '.accessToken')"
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { log "ERROR: admin auth failed"; exit 1; }

# ── Step 2: Resolve the service identity's client_id ─────────────────────────
log "Resolving client_id for identity $ROTATION_IDENTITY_ID..."
CLIENT_ID="$(curl -fsS "$HOST/api/v1/auth/universal-auth/identities/$ROTATION_IDENTITY_ID" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.identityUniversalAuth.clientId')"
[[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]] || { log "ERROR: could not resolve client_id"; exit 1; }

# ── Step 3: Capture old secret IDs (to revoke after overlap) ─────────────────
log "Capturing existing client secret IDs for later revocation..."
OLD_SECRET_IDS="$(curl -fsS \
  "$HOST/api/v1/auth/universal-auth/identities/$ROTATION_IDENTITY_ID/client-secrets" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.data[]?.id // empty' | tr '\n' ' ')"

# ── Step 4: Mint a fresh client secret ───────────────────────────────────────
log "Minting new client secret..."
NEW_SECRET="$(curl -fsS -X POST \
  "$HOST/api/v1/auth/universal-auth/identities/$ROTATION_IDENTITY_ID/client-secrets" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"description":"rotation-reload.service auto-rotation","ttl":0,"numUsesLimit":0}' \
  | jq -r '.clientSecret.clientSecret // .clientSecret')"
[[ -n "$NEW_SECRET" && "$NEW_SECRET" != "null" ]] || { log "ERROR: mint failed"; exit 1; }

# ── Step 5: Write new EnvironmentFile (chmod 600, atomic write) ───────────────
log "Writing new EnvironmentFile to $ROTATION_ENV_FILE..."
umask 077
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT
cat > "$TMP_FILE" << ENVEOF
INFISICAL_CLIENT_ID=$CLIENT_ID
INFISICAL_CLIENT_SECRET=$NEW_SECRET
INFISICAL_PROJECT_ID=$ROTATION_PROJECT_ID
ENVEOF
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$ROTATION_ENV_FILE"
log "EnvironmentFile updated."

# ── Step 6: Send SIGHUP — triggers installSighupReload() in the service ───────
log "Sending SIGHUP to $ROTATION_SERVICE_NAME..."
systemctl kill --signal=SIGHUP "$ROTATION_SERVICE_NAME"
log "SIGHUP sent. Service's refreshSecrets() will re-auth with new credential."

# ── Step 7: Wait for overlap window, then revoke old secrets ──────────────────
if [[ -n "$OLD_SECRET_IDS" ]]; then
  log "Waiting ${OVERLAP}s overlap window before revoking old secrets..."
  sleep "$OVERLAP"

  for SECRET_ID in $OLD_SECRET_IDS; do
    log "Revoking old secret $SECRET_ID..."
    REVOKE_STATUS="$(curl -fsS -o /dev/null -w "%{http_code}" -X DELETE \
      "$HOST/api/v1/auth/universal-auth/identities/$ROTATION_IDENTITY_ID/client-secrets/$SECRET_ID" \
      -H "Authorization: Bearer $TOKEN")"
    if [[ "$REVOKE_STATUS" == "200" || "$REVOKE_STATUS" == "204" ]]; then
      log "Revoked $SECRET_ID (HTTP $REVOKE_STATUS)"
    else
      log "WARNING: revoke of $SECRET_ID returned HTTP $REVOKE_STATUS — may already be expired"
    fi
  done
else
  log "No old secrets found to revoke."
fi

log "Rotation complete for $ROTATION_SERVICE_NAME."
