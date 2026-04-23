output "db_private_ip" {
  value     = google_sql_database_instance.infisical.private_ip_address
  sensitive = true
}

output "db_instance_name" {
  value = google_sql_database_instance.infisical.name
}
