module "gke" {
  source = "./modules/gke"

  project_id             = var.project_id
  region                 = var.region
  cluster_name           = var.cluster_name
  node_pool_machine_type = var.node_pool_machine_type
  node_pool_min_count    = var.node_pool_min_count
  node_pool_max_count    = var.node_pool_max_count
  master_authorized_cidr = var.master_authorized_cidr

  depends_on = [google_project_service.apis]
}

module "gcp" {
  source = "./modules/gcp"

  project_id   = var.project_id
  region       = var.region
  cluster_name = var.cluster_name

  # Workload Identity bindings need the cluster's project number
  project_number = data.google_project.project.number

  depends_on = [module.gke]
}

module "databases" {
  source = "./modules/databases"

  project_id        = var.project_id
  region            = var.region
  vpc_network_id    = module.gke.vpc_network_id
  db_tier           = var.db_tier
  infisical_db_password = var.infisical_db_password

  depends_on = [module.gke, google_project_service.apis]
}

module "deployments" {
  source = "./modules/deployments"

  project_id                   = var.project_id
  region                       = var.region
  cluster_name                 = var.cluster_name
  image_registry               = var.image_registry
  image_tag                    = var.image_tag
  argocd_admin_password_bcrypt = var.argocd_admin_password_bcrypt
  infisical_db_host            = module.databases.db_private_ip
  infisical_db_password        = var.infisical_db_password
  infisical_encryption_key     = var.infisical_encryption_key
  infisical_auth_secret        = var.infisical_auth_secret
  workload_identity_sa_email   = module.gcp.workload_identity_sa_email

  depends_on = [module.gke, module.gcp, module.databases]
}
