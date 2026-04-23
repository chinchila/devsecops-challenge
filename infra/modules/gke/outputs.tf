output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true
}

output "ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "vpc_network_id" {
  value = google_compute_network.vpc.id
}

output "subnet_id" {
  value = google_compute_subnetwork.nodes.id
}
