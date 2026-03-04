# CNPG Off-Site DR Backup Infrastructure
#
# This creates:
# - GCS bucket for CNPG DR replica backups (uses shared KMS key from kms.tf)
# - Service account with bucket-scoped Storage Object Admin role
#
# Architecture: DR replica clusters (odoo-pg-dr, chatwoot-pg-dr) read WAL from
# MinIO on TrueNAS (LAN) and archive their own WAL + base backups to this GCS
# bucket. Upload-only in normal operation — download egress only during DR recovery.
#
# After applying, create a SA key and save to 1Password:
#   gcloud iam service-accounts keys create /tmp/cnpg-gcs-sa.json \
#     --iam-account=$(terraform -chdir=terraform/gcp output -raw cnpg_backup_sa_email)
#   # Save JSON contents to 1Password item "cnpg-gcs-credentials":
#   #   Field name: gcsCredentials
#   #   Field value: <entire JSON key file contents>
#   rm /tmp/cnpg-gcs-sa.json

locals {
  cnpg_backup_bucket = "hayden-cnpg-backups"
}

# -----------------------------------------------------------------------------
# GCS Bucket for CNPG DR replica backups
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "cnpg_backups" {
  name                        = local.cnpg_backup_bucket
  location                    = upper(local.kms_location)
  project                     = var.project_id
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  encryption {
    default_kms_key_name = google_kms_crypto_key.backup_encryption.id
  }

  # Downgrade to Nearline after 30 days (WAL segments are small, base backups larger)
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  # Delete backups older than 90 days
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  # 7-day soft delete protects against accidental deletion without versioning overhead
  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  depends_on = [
    google_kms_crypto_key_iam_member.gcs_backup_encryption
  ]
}

# -----------------------------------------------------------------------------
# Service Account for CNPG DR replicas
# -----------------------------------------------------------------------------

resource "google_service_account" "cnpg_backup" {
  account_id   = "cnpg-dr-backup"
  display_name = "CNPG DR Replica Backup"
  description  = "Service account for CNPG DR replica clusters to archive WAL and base backups to GCS"
}

# Grant SA permission to read/write/delete objects in the bucket
resource "google_storage_bucket_iam_member" "cnpg_backup_object_admin" {
  bucket = google_storage_bucket.cnpg_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cnpg_backup.email}"
}

# CNPG also needs storage.buckets.get for bucket operations
resource "google_storage_bucket_iam_member" "cnpg_backup_bucket_reader" {
  bucket = google_storage_bucket.cnpg_backups.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.cnpg_backup.email}"
}

# SA key managed externally: create via gcloud, save JSON to 1Password (cnpg-gcs-credentials)

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "cnpg_backup_sa_email" {
  value       = google_service_account.cnpg_backup.email
  description = "Email of the CNPG DR backup service account"
}

output "cnpg_backup_bucket" {
  value       = google_storage_bucket.cnpg_backups.name
  description = "GCS bucket name for CNPG DR replica backups"
}
