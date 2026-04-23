resource "google_sql_database_instance" "infisical" {
  project          = var.project_id
  name             = "infisical-pg"
  database_version = "POSTGRES_15"
  region           = var.region

  deletion_protection = false

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_autoresize   = false
    disk_size         = 10
    disk_type         = "PD_SSD"

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.vpc_network_id
      ssl_mode = "ENCRYPTED_ONLY"
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
  }
}

resource "google_sql_database" "infisical" {
  project  = var.project_id
  name     = "infisical"
  instance = google_sql_database_instance.infisical.name
}

resource "google_sql_user" "infisical" {
  project  = var.project_id
  name     = "infisical"
  instance = google_sql_database_instance.infisical.name
  password = var.infisical_db_password
}
