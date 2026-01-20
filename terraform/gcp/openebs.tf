# OpenEBS Volume Snapshot Backup Infrastructure
#
# This creates:
# - GCS bucket for OpenEBS volume snapshots (uses shared KMS key from kms.tf)
# - Service account with bucket-scoped Storage Object Admin role
#
# SA key managed externally via 1Password (openebs-objstore)

locals {
  openebs_bucket = "hayden-openebs-backups"
}

# -----------------------------------------------------------------------------
# GCS Bucket for OpenEBS snapshots
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "openebs" {
  name                        = local.openebs_bucket
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
# Service Account for OpenEBS
# -----------------------------------------------------------------------------

resource "google_service_account" "openebs" {
  account_id   = "openebs-backup"
  display_name = "OpenEBS Volume Snapshot Backup"
  description  = "Service account for OpenEBS to store volume snapshots in GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "openebs_object_admin" {
  bucket = google_storage_bucket.openebs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.openebs.email}"
}

# OpenEBS also needs storage.buckets.get for bucket operations
resource "google_storage_bucket_iam_member" "openebs_bucket_reader" {
  bucket = google_storage_bucket.openebs.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.openebs.email}"
}

# SA key managed externally via 1Password (openebs-objstore)

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "openebs_sa_email" {
  value       = google_service_account.openebs.email
  description = "Email of the OpenEBS service account"
}

output "openebs_bucket" {
  value       = google_storage_bucket.openebs.name
  description = "GCS bucket name for OpenEBS snapshots"
}
