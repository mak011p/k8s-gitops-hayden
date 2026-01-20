# Magento 2 (Auntalma) PostgreSQL Backup Infrastructure
#
# This creates:
# - GCS bucket for Barman backups (uses shared KMS key from kms.tf)
# - Service account with Storage Object Admin role
#
# After applying, retrieve the SA key and save to 1Password:
#   terraform output -raw magento2_backup_sa_key | base64 -d > /tmp/magento2-sa-key.json
#   # Copy contents to 1Password item "magento2-objstore" field "serviceAccount"

locals {
  magento2_backup_bucket = "hayden-magento2-backups"
}

# -----------------------------------------------------------------------------
# GCS Bucket for CNPG/Barman backups
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
# Service Account for CNPG/Barman
# -----------------------------------------------------------------------------

resource "google_service_account" "magento2_backup" {
  account_id   = "magento2-pg-backup"
  display_name = "Magento 2 PostgreSQL Backup (CNPG/Barman)"
  description  = "Service account for CNPG to write PostgreSQL backups to GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "magento2_backup_object_admin" {
  bucket = google_storage_bucket.magento2_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.magento2_backup.email}"
}

# Barman Cloud also needs storage.buckets.get for WAL archive checks
resource "google_storage_bucket_iam_member" "magento2_backup_bucket_reader" {
  bucket = google_storage_bucket.magento2_backups.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.magento2_backup.email}"
}

# SA key managed externally via 1Password (magento2-objstore)

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
