variable "project_id" { type = string }
variable "region" { type = string }
variable "vpc_network_id" { type = string }
variable "db_tier" { type = string }
variable "infisical_db_password" {
  type      = string
  sensitive = true
}
