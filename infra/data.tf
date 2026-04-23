data "google_client_config" "default" {}

data "google_project" "project" {
  project_id = var.project_id
}

data "google_container_cluster" "primary" {
  name     = module.gke.cluster_name
  location = var.region
  project  = var.project_id

  depends_on = [module.gke]
}
