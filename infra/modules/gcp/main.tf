resource "google_service_account" "workload" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-workload"
  display_name = "Workload Identity SA for app services"
}

# Allow the k8s service account to impersonate this GCP SA
resource "google_service_account_iam_binding" "workload_identity_binding" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[service-1/service-1]",
    "serviceAccount:${var.project_id}.svc.id.goog[service-2/service-2]",
    "serviceAccount:${var.project_id}.svc.id.goog[service-3/service-3]",
  ]
}

# Minimal IAM for the workload SA - only Secret Manager read
resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.workload.email}"
}

resource "google_service_account" "infisical" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-infisical"
  display_name = "Infisical self-hosted SA"
}

resource "google_service_account_iam_binding" "infisical_workload_identity" {
  service_account_id = google_service_account.infisical.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[infisical/infisical]",
  ]
}

resource "google_project_iam_member" "infisical_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.infisical.email}"
}
