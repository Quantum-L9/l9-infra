terraform {
  required_providers {
    infisical = {
      source = "Infisical/infisical"
    }
  }
}

# ── Per-app project (blast-radius isolation) ──────────────────────────────────
resource "infisical_project" "this" {
  name = var.display_name
  slug = var.slug
}

# ── Machine identity for the app's runtime (VPS / CI) ─────────────────────────
# Org role is no-access; the only grant is the read-only project binding below.
resource "infisical_identity" "this" {
  name   = "${var.slug}-runtime"
  org_id = var.org_id
  role   = "no-access"
}

# ── Universal Auth: how the runtime authenticates ─────────────────────────────
# The client_id is created here; the client_secret is minted out-of-band by
# scripts/issue-client-secret.sh so it never enters Terraform state.
# access_token_max_ttl = 30d matches rotation-reload.timer OnUnitActiveSec=25d cadence.
resource "infisical_identity_universal_auth" "this" {
  identity_id = infisical_identity.this.id

  dynamic "access_token_trusted_ips" {
    for_each = var.trusted_ips
    content {
      ip_address = access_token_trusted_ips.value
    }
  }

  dynamic "client_secret_trusted_ips" {
    for_each = var.trusted_ips
    content {
      ip_address = client_secret_trusted_ips.value
    }
  }

  access_token_ttl            = 2592000 # 30d — matches rotation-reload.timer cadence
  access_token_max_ttl        = 2592000 # 30d
  access_token_num_uses_limit = 0       # unlimited
}

# ── Read-only binding of the identity to its project ──────────────────────────
resource "infisical_project_identity" "this" {
  project_id  = infisical_project.this.id
  identity_id = infisical_identity.this.id

  roles = [{
    role_slug = "viewer" # built-in read-only role
  }]
}

# ── Optional: import shared keys from platform-common ─────────────────────────
# Enable per-service via import_common = true in services.tf after confirming
# cross-project infisical_secret_import attribute names on your pinned provider
# version (~> 0.15). Run `terraform plan` first — adjust any flagged attributes.
#
# When enabled, secrets in platform-common/<environment_slug>/ at folder_path "/"
# become readable in this project's environment via Infisical secret references,
# so OPENROUTER_API_KEY, PERPLEXITY_API_KEY, etc. are rotated in one place only.
resource "infisical_secret_import" "common" {
  count = var.import_common ? 1 : 0

  project_id       = infisical_project.this.id
  environment_slug = var.environment_slug
  folder_path      = "/"

  import_environment_slug = var.environment_slug
  import_folder_path      = "/"

  # The attribute that names the source project differs between provider minor
  # versions. If `terraform plan` flags this block, uncomment one of:
  # source_project_id  = var.common_project_id   # older provider attribute name
  # For provider >= 0.14 the import source is typically set via a separate
  # infisical_secret_import_from block — check `terraform plan` output.
  # See: https://registry.terraform.io/providers/Infisical/infisical/latest/docs
}
