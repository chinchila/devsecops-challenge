output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_endpoint" {
  value     = module.gke.endpoint
  sensitive = true
}

output "kubeconfig_command" {
  value = "gcloud container clusters get-credentials ${module.gke.cluster_name} --region ${var.region} --project ${var.project_id}"
}

output "argocd_url" {
  value = "https://argocd.${module.gke.cluster_name}.internal (port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443)"
}

output "infisical_db_private_ip" {
  value     = module.databases.db_private_ip
  sensitive = true
}
