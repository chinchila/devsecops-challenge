provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Kubernetes provider - depends on GKE cluster output
provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.endpoint}"
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

provider "kubectl" {
  host                   = "https://${module.gke.endpoint}"
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  token                  = data.google_client_config.default.access_token
  load_config_file       = false
}
