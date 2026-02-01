# Velero Cluster Backup Infrastructure
#
# This creates:
# - GCS bucket for Velero backups (uses shared KMS key from kms.tf)
# - Service account with bucket-scoped Storage Object Admin role
#
# SA key managed externally via 1Password (velero-gcs)

locals {
  velero_bucket = "hayden-velero-backups"
}

# -----------------------------------------------------------------------------
# GCS Bucket for Velero backups
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "velero" {
  name                        = local.velero_bucket
  location                    = upper(local.kms_location)
  project                     = var.project_id
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  encryption {
    default_kms_key_name = google_kms_crypto_key.backup_encryption.id
  }

  # Downgrade to Nearline after 14 days
  lifecycle_rule {
    condition {
      age = 14
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  # Delete backups older than 60 days
  lifecycle_rule {
    condition {
      age = 60
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [
    google_kms_crypto_key_iam_member.gcs_backup_encryption
  ]
}

# -----------------------------------------------------------------------------
# Service Account for Velero
# -----------------------------------------------------------------------------

resource "google_service_account" "velero" {
  account_id   = "velero"
  display_name = "Velero Cluster Backup"
  description  = "Service account for Velero to store cluster backups in GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "velero_object_admin" {
  bucket = google_storage_bucket.velero.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.velero.email}"
}

# Velero also needs storage.buckets.get for bucket operations
resource "google_storage_bucket_iam_member" "velero_bucket_reader" {
  bucket = google_storage_bucket.velero.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.velero.email}"
}

# SA key managed externally via 1Password (velero-gcs)

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "velero_sa_email" {
  value       = google_service_account.velero.email
  description = "Email of the Velero service account"
}

output "velero_bucket" {
  value       = google_storage_bucket.velero.name
  description = "GCS bucket name for Velero backups"
}
