# Chatwoot PostgreSQL (CNPG) Backup Infrastructure
#
# This creates:
# - GCS bucket for Barman backups (uses shared KMS key from kms.tf)
# - Dedicated service account with Storage Object Admin role
#
# After applying, retrieve the SA key and save to 1Password:
#   terraform output -raw chatwoot_backup_sa_key | base64 -d > /tmp/chatwoot-sa-key.json
#   # Copy contents to 1Password item "chatwoot-objstore" field "serviceAccount"

locals {
  chatwoot_backup_bucket = "hayden-chatwoot-backups"
}

# -----------------------------------------------------------------------------
# GCS Bucket for CNPG/Barman backups
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "chatwoot_backups" {
  name                        = local.chatwoot_backup_bucket
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

resource "google_service_account" "chatwoot_backup" {
  account_id   = "chatwoot-pg-backup"
  display_name = "Chatwoot PostgreSQL Backup (CNPG/Barman)"
  description  = "Service account for CNPG to write Chatwoot PostgreSQL backups to GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "chatwoot_backup_object_admin" {
  bucket = google_storage_bucket.chatwoot_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.chatwoot_backup.email}"
}

# Barman Cloud also needs storage.buckets.get for WAL archive checks
resource "google_storage_bucket_iam_member" "chatwoot_backup_bucket_reader" {
  bucket = google_storage_bucket.chatwoot_backups.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.chatwoot_backup.email}"
}

# Generate SA key for 1Password
resource "google_service_account_key" "chatwoot_backup" {
  service_account_id = google_service_account.chatwoot_backup.name
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "chatwoot_backup_sa_email" {
  value       = google_service_account.chatwoot_backup.email
  description = "Email of the Chatwoot backup service account"
}

output "chatwoot_backup_bucket" {
  value       = google_storage_bucket.chatwoot_backups.name
  description = "GCS bucket name for Chatwoot backups"
}

output "chatwoot_backup_sa_key" {
  value       = google_service_account_key.chatwoot_backup.private_key
  description = "Base64-encoded SA key for 1Password (decode with: base64 -d)"
  sensitive   = true
}
