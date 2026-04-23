terraform {
  required_version = ">= 1.7"

  backend "gcs" {
    # Populated via -backend-config at init time:
    #   terraform init \
    #     -backend-config="bucket=<YOUR_TF_STATE_BUCKET>" \
    #     -backend-config="prefix=devsecops-challenge/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.30"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
