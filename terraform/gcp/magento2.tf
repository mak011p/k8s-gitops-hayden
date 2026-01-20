# Magento 2 (Auntalma) Backup Infrastructure
#
# This creates:
# - GCS bucket for MariaDB backups (uses shared KMS key from kms.tf)
# - Service account with Storage Object Admin role
# - HMAC keys for S3-compatible access (required by MariaDB operator)
#
# After applying, save HMAC keys to 1Password:
#   terraform -chdir=terraform/gcp output magento2_hmac_access_id
#   terraform -chdir=terraform/gcp output -raw magento2_hmac_secret
#   # Save to 1Password item "magento2-objstore":
#   #   accessKeyId: <access_id>
#   #   secretAccessKey: <secret>

locals {
  magento2_backup_bucket = "hayden-magento2-backups"
}

# -----------------------------------------------------------------------------
# GCS Bucket for MariaDB backups
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "magento2_backups" {
  name                        = local.magento2_backup_bucket
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

  # Lifecycle rule: delete old backups after 30 days (CNPG also has 7d retention)
  lifecycle_rule {
    condition {
      age = 30
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
# Service Account for MariaDB Backups
# -----------------------------------------------------------------------------

resource "google_service_account" "magento2_backup" {
  account_id   = "magento2-pg-backup"
  display_name = "Auntalma MariaDB Backup"
  description  = "Service account for MariaDB operator to write Auntalma backups to GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "magento2_backup_object_admin" {
  bucket = google_storage_bucket.magento2_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.magento2_backup.email}"
}

# Also needs storage.buckets.get for bucket operations
resource "google_storage_bucket_iam_member" "magento2_backup_bucket_reader" {
  bucket = google_storage_bucket.magento2_backups.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.magento2_backup.email}"
}

# -----------------------------------------------------------------------------
# HMAC Keys for S3-compatible access (MariaDB operator)
# -----------------------------------------------------------------------------

resource "google_storage_hmac_key" "magento2_backup" {
  service_account_email = google_service_account.magento2_backup.email
  project               = var.project_id
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "magento2_backup_sa_email" {
  value       = google_service_account.magento2_backup.email
  description = "Email of the Magento 2 backup service account"
}

output "magento2_backup_bucket" {
  value       = google_storage_bucket.magento2_backups.name
  description = "GCS bucket name for Magento 2 backups"
}

output "magento2_hmac_access_id" {
  value       = google_storage_hmac_key.magento2_backup.access_id
  description = "HMAC access ID for S3-compatible access (save to 1Password accessKeyId)"
}

output "magento2_hmac_secret" {
  value       = google_storage_hmac_key.magento2_backup.secret
  description = "HMAC secret for S3-compatible access (save to 1Password secretAccessKey)"
  sensitive   = true
}
