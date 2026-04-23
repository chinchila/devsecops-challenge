resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "nodes" {
  project       = var.project_id
  name          = "${var.cluster_name}-nodes"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.4.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.8.0.0/20"
  }
}

resource "google_compute_global_address" "private_service" {
  project       = var.project_id
  name          = "${var.cluster_name}-private-svc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_svc_conn" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service.name]
}

resource "google_compute_router" "router" {
  project = var.project_id
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  project                            = var.project_id
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Negar todo acesso ingress por padrão, apenas healthcheck e istio
resource "google_compute_firewall" "deny_all_ingress" {
  project  = var.project_id
  name     = "${var.cluster_name}-deny-all-ingress"
  network  = google_compute_network.vpc.id
  priority = 65534

  deny {
    protocol = "all"
  }

  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_internal" {
  project  = var.project_id
  name     = "${var.cluster_name}-allow-internal"
  network  = google_compute_network.vpc.id
  priority = 1000

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  direction     = "INGRESS"
  source_ranges = ["10.0.0.0/8"]
}

resource "google_compute_firewall" "allow_health_checks" {
  project  = var.project_id
  name     = "${var.cluster_name}-allow-health-checks"
  network  = google_compute_network.vpc.id
  priority = 900

  allow {
    protocol = "tcp"
    ports    = ["8080", "15021"] # app + Istio health
  }

  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"] # GCP health checkers
}

resource "google_container_cluster" "primary" {
  provider = google-beta

  project  = var.project_id
  name     = var.cluster_name
  location = var.region

  release_channel {
    channel = "RAPID"
  }

  # Separate node pool below - default pool is deleted immediately after cluster creation.
  # node_config here controls the throwaway default pool disk size so it doesn't
  # consume 100 GB pd-ssd quota during the brief window before deletion.
  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    disk_type    = "pd-standard"   # standard HDD - not counted against pd-ssd quota
    disk_size_gb = 30
    machine_type = "e2-medium"
  }

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  resource_labels = {
    environment = "production"
    team        = "security"
    managedby   = "terraform"
  }

  # Private cluster - nodes have no public IPs
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # keep public endpoint for operator access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.master_authorized_cidr
      display_name = "operator-access"
    }
  }

  # eBPF datapath (ADVANCED_DATAPATH)
  datapath_provider = "ADVANCED_DATAPATH"

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Shielded nodes
  enable_shielded_nodes = true

  # Disable legacy endpoints
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Logging and monitoring
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  enable_legacy_abac = false

  addons_config {
    # Disable Kubernetes Dashboard (security risk)
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    network_policy_config {
      # NetworkPolicy enforcement is handled by Istio CNI in ADVANCED_DATAPATH
      disabled = true
    }
  }

  network_policy {
    enabled  = false # Replaced by Cilium (ADVANCED_DATAPATH)
    provider = "PROVIDER_UNSPECIFIED"
  }

  # Binary Authorization - PERMISSIVE for now, documented as residual risk
  binary_authorization {
    evaluation_mode = "DISABLED"
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }
}

resource "google_container_node_pool" "primary" {
  provider = google-beta

  project    = var.project_id
  name       = "primary"
  location   = var.region
  cluster    = google_container_cluster.primary.name

  autoscaling {
    min_node_count = var.node_pool_min_count
    max_node_count = var.node_pool_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.node_pool_machine_type
    disk_type    = "pd-standard"
    disk_size_gb = 30

    # Workload Identity per node
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded instance
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Minimal OAuth scopes - Workload Identity handles auth
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    metadata = {
      # Block access to legacy metadata endpoint
      disable-legacy-endpoints = "true"
    }

    labels = {
      env     = "production"
      cluster = var.cluster_name
    }

    tags = ["gke-node", var.cluster_name]
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}
