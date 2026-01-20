# Nextcloud Backup Infrastructure
#
# This creates:
# - GCS bucket for VolSync/Restic backups (uses shared KMS key from kms.tf)
# - Service account with bucket-scoped Storage Object Admin role
#
# SA key managed externally via 1Password (nextcloud-objstore)

locals {
  nextcloud_backup_bucket = "hayden-nextcloud-backups"
}

# -----------------------------------------------------------------------------
# GCS Bucket for VolSync/Restic backups
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "nextcloud_backups" {
  name                        = local.nextcloud_backup_bucket
  location                    = upper(local.kms_location)
  project                     = var.project_id
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  encryption {
    default_kms_key_name = google_kms_crypto_key.backup_encryption.id
  }

  versioning {
    enabled = false
  }

  # Lifecycle rule: delete old backups after 90 days
  lifecycle_rule {
    condition {
      age = 90
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
# Service Account for VolSync/Restic
# -----------------------------------------------------------------------------

resource "google_service_account" "nextcloud_backup" {
  account_id   = "nextcloud-backup"
  display_name = "Nextcloud Backup (VolSync/Restic)"
  description  = "Service account for VolSync to write Nextcloud backups to GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "nextcloud_backup_object_admin" {
  bucket = google_storage_bucket.nextcloud_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.nextcloud_backup.email}"
}

# VolSync/Restic also needs storage.buckets.get for rclone operations
resource "google_storage_bucket_iam_member" "nextcloud_backup_bucket_reader" {
  bucket = google_storage_bucket.nextcloud_backups.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.nextcloud_backup.email}"
}

# SA key managed externally via 1Password (nextcloud-objstore)

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "nextcloud_backup_sa_email" {
  value       = google_service_account.nextcloud_backup.email
  description = "Email of the Nextcloud backup service account"
}

output "nextcloud_backup_bucket" {
  value       = google_storage_bucket.nextcloud_backups.name
  description = "GCS bucket name for Nextcloud backups"
}
