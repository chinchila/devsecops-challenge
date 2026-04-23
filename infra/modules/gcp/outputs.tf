output "workload_identity_sa_email" {
  value = google_service_account.workload.email
}

output "infisical_sa_email" {
  value = google_service_account.infisical.email
}
