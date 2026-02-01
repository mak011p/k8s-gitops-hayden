terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }

  backend "gcs" {
    bucket = "hayden-k8s-terraform-state"
    prefix = "gcp"
  }
}
