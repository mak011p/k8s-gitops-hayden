# Dev Database Seeds — Sanitised dev DB dumps for local development
#
# Completely isolated from production backup infrastructure:
# - No KMS encryption (unnecessary for sanitised dev data)
# - No service account (authenticated via `gcloud auth login`)
# - Separate bucket with clear "dev" naming
#
# Usage:
#   gsutil cp backups/odoo-dev.sql.gz gs://hayden-dev-seeds/odoo/
#   gsutil cp gs://hayden-dev-seeds/odoo/odoo-dev.sql.gz backups/

locals {
  dev_seeds_bucket = "hayden-dev-seeds"
}

# -----------------------------------------------------------------------------
# GCS Bucket for dev database seeds
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "dev_seeds" {
  name                        = local.dev_seeds_bucket
  location                    = upper(local.kms_location) # australia-southeast2
  project                     = var.project_id
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # No KMS encryption — Google-managed encryption is sufficient for dev data

  # Delete dumps older than 90 days to avoid stale accumulation
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}

# -----------------------------------------------------------------------------
# IAM — Allow the developer's Google account to read/write
# -----------------------------------------------------------------------------

# No service account needed. Developers authenticate via:
#   gcloud auth login
#   gsutil cp ...
#
# If you need to grant access to additional users, add them here:
# resource "google_storage_bucket_iam_member" "dev_seeds_user" {
#   bucket = google_storage_bucket.dev_seeds.name
#   role   = "roles/storage.objectAdmin"
#   member = "user:someone@example.com"
# }

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "dev_seeds_bucket" {
  value       = google_storage_bucket.dev_seeds.name
  description = "GCS bucket name for dev database seeds"
}
