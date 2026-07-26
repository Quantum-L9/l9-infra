locals {
  # ── The service registry ──────────────────────────────────────────────────
  # Add a repo/service to secret management by adding ONE entry here, then
  # `terraform apply` + issue-client-secret.sh. Each entry gets its own Infisical
  # project + a read-only machine identity scoped to it.
  #
  #   display_name  : human name / Infisical project name
  #   slug          : url-safe id (project slug + identity name prefix)
  #   trusted_ips   : CIDRs the runtime may authenticate from.
  #                   Currently 0.0.0.0/0 — lock to VPS CIDRs when ready.
  #   import_common : pull shared keys from platform-common (see common.tf).
  #                   Shared keys: OPENROUTER_API_KEY, PERPLEXITY_API_KEY,
  #                   DATAFORSEO_LOGIN, DATAFORSEO_PASSWORD.
  #                   Set to true after running `terraform plan` to confirm
  #                   infisical_secret_import attribute names on provider ~> 0.15.
  #
  # Rotation:
  #   Each service's systemd EnvironmentFile is rotated by infra-rotation-reload.sh
  #   via rotation-reload.timer (every 25d, overlap window 300s before revoke).
  #   Deploy the systemd units from infra/systemd/ and the admin env file at
  #   /etc/infisical-admin/rotation.env (chmod 600, root:root) per service host.

  services = {
    seo_bot = {
      display_name  = "SEO-Bot"
      slug          = "seo-bot"
      trusted_ips   = ["0.0.0.0/0"] # TODO: lock to VPS CIDR when ready
      import_common = false          # flip to true after provider attr validation
    }
    website_bot = {
      display_name  = "Website-Bot"
      slug          = "website-bot"
      trusted_ips   = ["0.0.0.0/0"] # TODO: lock to VPS CIDR when ready
      import_common = false          # flip to true after provider attr validation
    }
  }
}
