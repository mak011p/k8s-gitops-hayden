# Billing Guard - Auto-disable billing when budget exceeded
#
# This creates:
# - Pub/Sub topic for budget alert notifications
# - Cloud Function (Gen2) that disables project billing when cost >= 100% of budget
# - Billing budget at $200 AUD/month with alerts at 50%, 80%, 100%
# - IAM binding so the Cloud Function SA can disable billing
#
# IMPORTANT: If this function triggers, ALL GCP services will stop.
# Re-enable billing manually in the GCP Console to restore services.

# -----------------------------------------------------------------------------
# Required APIs
# -----------------------------------------------------------------------------

resource "google_project_service" "billing_guard" {
  for_each = toset([
    "pubsub.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "billingbudgets.googleapis.com",
  ])

  project = var.project_id
  service = each.value
}

# -----------------------------------------------------------------------------
# Pub/Sub Topic for Budget Alerts
# -----------------------------------------------------------------------------

resource "google_pubsub_topic" "billing_alerts" {
  name    = "billing-alerts"
  project = var.project_id

  depends_on = [google_project_service.billing_guard]
}

# -----------------------------------------------------------------------------
# Cloud Function Source Code
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "billing_guard_source" {
  name                        = "${var.project_id}-billing-guard-src"
  location                    = upper(local.kms_location)
  project                     = var.project_id
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

data "archive_file" "billing_guard" {
  type        = "zip"
  output_path = "${path.module}/billing-guard.zip"

  source {
    content  = <<-PYTHON
import base64
import json
import os
from googleapiclient import discovery

PROJECT_ID = os.getenv("GCP_PROJECT", "${var.project_id}")
BUDGET_THRESHOLD = float(os.getenv("BUDGET_THRESHOLD", "1.0"))


def stop_billing(data, context):
    """Disables billing on the project when cost exceeds threshold."""
    pubsub_data = base64.b64decode(data["data"]).decode("utf-8")
    pubsub_json = json.loads(pubsub_data)

    cost_amount = pubsub_json.get("costAmount", 0)
    budget_amount = pubsub_json.get("budgetAmount", 0)

    if budget_amount == 0:
        print("Budget amount is 0, skipping")
        return

    ratio = cost_amount / budget_amount
    print(f"Cost: {cost_amount}, Budget: {budget_amount}, Ratio: {ratio:.2%}")

    if ratio >= BUDGET_THRESHOLD:
        print(f"THRESHOLD EXCEEDED ({ratio:.2%} >= {BUDGET_THRESHOLD:.0%}). DISABLING BILLING.")
        billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
        billing_info = (
            billing.projects()
            .updateBillingInfo(
                name=f"projects/{PROJECT_ID}",
                body={"billingAccountName": ""},
            )
            .execute()
        )
        print(f"Billing disabled: {billing_info}")
    else:
        print(f"Under threshold ({ratio:.2%} < {BUDGET_THRESHOLD:.0%}). No action.")
PYTHON
    filename = "main.py"
  }

  source {
    content  = "google-api-python-client>=2.0.0\n"
    filename = "requirements.txt"
  }
}

resource "google_storage_bucket_object" "billing_guard" {
  name   = "billing-guard-${data.archive_file.billing_guard.output_md5}.zip"
  bucket = google_storage_bucket.billing_guard_source.name
  source = data.archive_file.billing_guard.output_path
}

# -----------------------------------------------------------------------------
# Cloud Function (Gen2)
# -----------------------------------------------------------------------------

resource "google_cloudfunctions2_function" "billing_guard" {
  name     = "billing-guard"
  location = local.kms_location
  project  = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "stop_billing"
    source {
      storage_source {
        bucket = google_storage_bucket.billing_guard_source.name
        object = google_storage_bucket_object.billing_guard.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = 60
    environment_variables = {
      GCP_PROJECT      = var.project_id
      BUDGET_THRESHOLD = "1.0"
    }
  }

  event_trigger {
    trigger_region = local.kms_location
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.billing_alerts.id
    retry_policy   = "RETRY_POLICY_DO_NOT_RETRY"
  }

  depends_on = [google_project_service.billing_guard]
}

# -----------------------------------------------------------------------------
# IAM: Allow Cloud Function SA to disable billing
# -----------------------------------------------------------------------------

resource "google_project_iam_member" "billing_guard_manager" {
  project = var.project_id
  role    = "roles/billing.projectManager"
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

data "google_compute_default_service_account" "default" {
  project = var.project_id
}

# -----------------------------------------------------------------------------
# Billing Budget
# -----------------------------------------------------------------------------

resource "google_billing_budget" "monthly_cap" {
  billing_account = var.billing_account
  display_name    = "GCS Cost Cap - Kill at 200AUD"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "AUD"
      units         = "200"
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  all_updates_rule {
    pubsub_topic = google_pubsub_topic.billing_alerts.id
  }
}
