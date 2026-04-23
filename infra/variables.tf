variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "devsecops-challenge"
}

variable "node_pool_machine_type" {
  description = "Machine type for the default node pool"
  type        = string
  default     = "e2-standard-2"
}

variable "node_pool_min_count" {
  type    = number
  default = 1
}

variable "node_pool_max_count" {
  type    = number
  default = 3
}

variable "master_authorized_cidr" {
  description = "CIDR allowed to reach the GKE API server. Restrict to your egress IP."
  type        = string
  # Replace with your actual egress IP: curl -s ifconfig.me
  default = "0.0.0.0/0" # TODO: restrict in production
}

variable "db_tier" {
  description = "Cloud SQL instance tier (for Infisical)"
  type        = string
  default     = "db-f1-micro"
}

variable "image_tag" {
  description = "Docker image tag for the three services"
  type        = string
  default     = "latest"
}

variable "image_registry" {
  description = "Container registry prefix (e.g. ghcr.io/org/repo)"
  type        = string
}

variable "argocd_admin_password_bcrypt" {
  description = "Bcrypt hash of the Argo CD admin password (htpasswd -nbBC 10 '' <password>)"
  type        = string
  sensitive   = true
}

variable "infisical_db_password" {
  description = "Password for the Infisical Cloud SQL user"
  type        = string
  sensitive   = true
}

variable "infisical_encryption_key" {
  description = "32-character hex encryption key for Infisical (openssl rand -hex 16)"
  type        = string
  sensitive   = true
}

variable "infisical_auth_secret" {
  description = "JWT signing secret for Infisical (openssl rand -base64 32)"
  type        = string
  sensitive   = true
}
