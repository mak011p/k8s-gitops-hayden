# Thanos Long-Term Metrics Storage
#
# This creates:
# - GCS bucket for Prometheus long-term storage (uses shared KMS key from kms.tf)
# - Service account with bucket-scoped Storage Object Admin role
#
# SA key managed externally via 1Password (thanos-objstore)

locals {
  thanos_bucket = "hayden-thanos-storage"
}

# -----------------------------------------------------------------------------
# GCS Bucket for Thanos metrics
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "thanos" {
  name                        = local.thanos_bucket
  location                    = upper(local.kms_location)
  project                     = var.project_id
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  encryption {
    default_kms_key_name = google_kms_crypto_key.backup_encryption.id
  }

  depends_on = [
    google_kms_crypto_key_iam_member.gcs_backup_encryption
  ]
}

# -----------------------------------------------------------------------------
# Service Account for Thanos
# -----------------------------------------------------------------------------

resource "google_service_account" "thanos" {
  account_id   = "thanos"
  display_name = "Thanos Long-Term Metrics Storage"
  description  = "Service account for Thanos to store Prometheus metrics in GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "thanos_object_admin" {
  bucket = google_storage_bucket.thanos.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.thanos.email}"
}

# Thanos also needs storage.buckets.get for bucket operations
resource "google_storage_bucket_iam_member" "thanos_bucket_reader" {
  bucket = google_storage_bucket.thanos.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.thanos.email}"
}

# SA key managed externally via 1Password (thanos-objstore)

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "thanos_sa_email" {
  value       = google_service_account.thanos.email
  description = "Email of the Thanos service account"
}

output "thanos_bucket" {
  value       = google_storage_bucket.thanos.name
  description = "GCS bucket name for Thanos metrics"
}
