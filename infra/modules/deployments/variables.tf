variable "project_id" { type = string }
variable "region" { type = string }
variable "cluster_name" { type = string }
variable "image_registry" { type = string }
variable "image_tag" { type = string }
variable "argocd_admin_password_bcrypt" {
  type      = string
  sensitive = true
}
variable "infisical_db_host" {
  type      = string
  sensitive = true
}
variable "infisical_db_password" {
  type      = string
  sensitive = true
}
variable "infisical_encryption_key" {
  description = "32-character hex encryption key for Infisical"
  type        = string
  sensitive   = true
}
variable "infisical_auth_secret" {
  description = "JWT signing secret for Infisical"
  type        = string
  sensitive   = true
}
variable "workload_identity_sa_email" { type = string }
