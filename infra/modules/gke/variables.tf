variable "project_id" { type = string }
variable "region" { type = string }
variable "cluster_name" { type = string }
variable "node_pool_machine_type" { type = string }
variable "node_pool_min_count" { type = number }
variable "node_pool_max_count" { type = number }
variable "master_authorized_cidr" { type = string }
variable "project_number" { type = string }

variable "create_kms_key" {
  type    = bool
  default = false
}