resource "google_sql_database_instance" "infisical" {
  project          = var.project_id
  name             = "infisical-pg"
  database_version = "POSTGRES_18"
  region           = var.region

  deletion_protection = false # Change in case of production

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
      ssl_mode        = "ENCRYPTED_ONLY"
      require_ssl     = true
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    database_flags {
      name  = "log_duration"
      value = "on"
    }

    database_flags {
      name  = "log_statement"
      value = "all"
    }

    database_flags {
      name  = "log_hostname"
      value = "on"
    }

    database_flags {
      name  = "log_min_messages"
      value = "error" 
    }

    database_flags {
      name  = "log_min_error_statement"
      value = "error"
    }

    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }

    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }

    database_flags {
      name  = "cloudsql.enable_pgaudit"
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
