# Systemd Rotation Deploy Guide

Deploys the automated Infisical secret rotation loop to a VPS host.
One setup per service (e.g. seo-bot, website-bot).

## What this installs

| File | Purpose |
|---|---|
| `rotation-reload.service` | Oneshot: re-issue secret → write EnvironmentFile → SIGHUP service |
| `rotation-reload.timer` | Fires service every 25 days (5-day margin before 30d TTL expires) |
| `infra-rotation-reload.sh` | The rotation logic (copy to `/usr/local/bin/`) |

## Prerequisites

- `curl`, `jq` installed on the host
- `terraform output identities` run to get `identity_id` and `project_id` per service
- A terraform-admin Infisical identity credential (`client_id` + `client_secret`)

## Deploy steps

```bash
# 1. Copy the rotation script
sudo cp scripts/infra-rotation-reload.sh /usr/local/bin/infra-rotation-reload.sh
sudo chmod 755 /usr/local/bin/infra-rotation-reload.sh

# 2. Create the admin credential file (one per host — NOT per service)
sudo mkdir -p /etc/infisical-admin
sudo tee /etc/infisical-admin/rotation.env > /dev/null << ENV
INFISICAL_ADMIN_CLIENT_ID=<terraform-admin-client-id>
INFISICAL_ADMIN_CLIENT_SECRET=<terraform-admin-client-secret>
ROTATION_IDENTITY_ID=<from terraform output identities.seo_bot.identity_id>
ROTATION_PROJECT_ID=<from terraform output identities.seo_bot.project_id>
ROTATION_SERVICE_NAME=seo-bot
ROTATION_ENV_FILE=/etc/seo-bot/infisical.env
ROTATION_OVERLAP_SECONDS=300
ENV
sudo chmod 600 /etc/infisical-admin/rotation.env
sudo chown root:root /etc/infisical-admin/rotation.env

# 3. Install systemd units
sudo cp systemd/rotation-reload.service /etc/systemd/system/rotation-reload.service
sudo cp systemd/rotation-reload.timer   /etc/systemd/system/rotation-reload.timer
sudo systemctl daemon-reload

# 4. Enable and start the timer
sudo systemctl enable --now rotation-reload.timer

# 5. Verify timer is scheduled
sudo systemctl list-timers rotation-reload.timer
```

## Verify rotation works (dry run)

```bash
# Trigger the service manually — should SIGHUP the target service
sudo systemctl start rotation-reload.service
sudo journalctl -u rotation-reload.service --no-pager -n 30
```

## Your service (e.g. seo-bot) must:

1. Call `installSighupReload({ logger })` from `@quantum-l9/infisical-config` at startup.
2. Point systemd `EnvironmentFile=` at `/etc/seo-bot/infisical.env`.
3. Have `ExecReload=kill -HUP $MAINPID` in its unit file so `systemctl reload` is equivalent to the timer's SIGHUP.

Example service unit snippet:
```ini
[Service]
EnvironmentFile=/etc/seo-bot/infisical.env
ExecStart=/usr/bin/node /opt/seo-bot/dist/index.js
ExecReload=kill -HUP $MAINPID
Restart=on-failure
```

## Rotation flow (full end-to-end)

```
rotation-reload.timer fires (every 25 days)
  → rotation-reload.service runs infra-rotation-reload.sh
      → auth as terraform-admin
      → capture old secret IDs
      → mint new client secret
      → write /etc/seo-bot/infisical.env (atomic, chmod 600)
      → systemctl kill --signal=SIGHUP seo-bot
          → SIGHUP handler in service calls refreshSecrets({ overwrite: true })
          → process.env updated with new INFISICAL_CLIENT_SECRET
          → service re-auths to Infisical with new credential on next secret fetch
      → wait 300s overlap window (old + new both valid)
      → revoke old secret IDs via Infisical API
  → Done. Zero downtime. Old credential dead. New credential live.
```
