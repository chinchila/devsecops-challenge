resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_namespace" "infisical" {
  metadata {
    name = "infisical"
    labels = {
      # Istio injection intentionally disabled: the secrets operator's admission
      # webhook must be reachable from the API server, which is outside the mesh
      # and cannot complete mTLS. Istio injection causes webhook call failures.
      "istio-injection" = "disabled"
    }
  }
}


resource "kubernetes_secret" "infisical_secrets" {
  metadata {
    name      = "infisical-secrets"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }

  data = {
    AUTH_SECRET           = var.infisical_auth_secret
    ENCRYPTION_KEY        = var.infisical_encryption_key
    # Podemos usar sslmode=require se tiver o cloudsql-ca no pod ou com DB_ROOT_CERT="<base64-encoded-certificate>"
    DB_CONNECTION_URI     = "postgresql://infisical:${var.infisical_db_password}@${var.infisical_db_host}:5432/infisical?sslmode=no-verify"
    SITE_URL              = "http://localhost"
    JWT_AUTH_LIFETIME     = "15m"  # Authentication tokens
    JWT_REFRESH_LIFETIME  = "24h"  # Refresh tokens
    JWT_SERVICE_LIFETIME  = "1h"   # Service tokens
  }

  type = "Opaque"
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

resource "kubernetes_namespace" "falco" {
  metadata {
    name = "falco"
  }
}

resource "kubernetes_namespace" "app" {
  for_each = toset(["service-1", "service-2", "service-3"])

  metadata {
    name = each.key
    labels = {
      "istio-injection"                    = "enabled"
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}

resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = "1.22.1"
  namespace        = kubernetes_namespace.istio_system.metadata[0].name
  create_namespace = false
  wait             = true
}

resource "helm_release" "istiod" {
  name             = "istiod"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  version          = "1.22.1"
  namespace        = kubernetes_namespace.istio_system.metadata[0].name
  create_namespace = false
  wait             = true

  values = [
    yamlencode({
      global = {
        meshID   = "mesh1"
        multiCluster = { clusterName = var.cluster_name }
        network  = var.cluster_name
      }
      meshConfig = {
        # Require mTLS for all services in the mesh
        defaultConfig = {
          proxyStatsMatcher = {
            inclusionRegexps = [".*"]
          }
        }
        # Enable access logging to stdout for Falco correlation
        accessLogFile    = "/dev/stdout"
        accessLogEncoding = "JSON"
      }
      pilot = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
    })
  ]

  depends_on = [helm_release.istio_base]
}

# Istio ingress gateway
resource "helm_release" "istio_ingressgateway" {
  name             = "istio-ingressgateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = "1.22.1"
  namespace        = kubernetes_namespace.istio_system.metadata[0].name
  create_namespace = false
  wait             = true

  depends_on = [helm_release.istiod]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.11.1"
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  create_namespace = false
  wait             = true

  values = [
    yamlencode({
      global = {
        securityContext = {
          runAsNonRoot = true
          runAsUser    = 999
          fsGroup      = 999
        }
      }
      configs = {
        secret = {
          argocdServerAdminPassword = var.argocd_admin_password_bcrypt
        }
        params = {
          # Disable insecure mode - TLS always on
          "server.insecure" = false
        }
      }
      server = {
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
      repoServer = {
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "256Mi" }
        }
      }
      applicationSet = { enabled = true }
      notifications  = { enabled = false }
    })
  ]

  depends_on = [helm_release.istiod]
}

resource "helm_release" "infisical" {
  name             = "infisical"
  repository       = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart            = "infisical-standalone"
  version          = "1.8.0"
  namespace        = kubernetes_namespace.infisical.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300

   values = [
    templatefile("${path.module}/values-infisical.tftpl", {
      db_password = var.infisical_db_password
      db_host     = var.infisical_db_host
    })
  ]

  depends_on = [helm_release.istiod, kubernetes_secret.infisical_secrets]
}

# Infisical Secrets Operator
resource "helm_release" "infisical_operator" {
  name             = "infisical-operator"
  repository       = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart            = "secrets-operator"
  version          = "0.10.32"
  namespace        = kubernetes_namespace.infisical.metadata[0].name
  create_namespace = false
  wait             = true

  depends_on = [helm_release.infisical]
}

resource "helm_release" "prometheus" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus"
  version          = "29.2.1"
  namespace        = kubernetes_namespace.istio_system.metadata[0].name
  create_namespace = false
  wait             = true

  values = [
    yamlencode({
      server = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "1Gi" }
        }
        securityContext = {
          runAsNonRoot = true
          runAsUser    = 65534
          fsGroup      = 65534
        }
        # Scrape istiod and envoy-stats
        extraScrapeConfigs = ""
      }
      # Disable PushGateway - not needed
      pushgateway = { enabled = false }
    })
  ]

  depends_on = [helm_release.istiod]
}

resource "kubernetes_config_map" "falco_custom_rules" {
  metadata {
    name      = "falco-custom-rules"
    namespace = kubernetes_namespace.falco.metadata[0].name
  }

  data = yamldecode(file("${path.module}/../../../k8s/security/falco/custom-rules-configmap.yaml")).data

  depends_on = [kubernetes_namespace.falco]
}

resource "helm_release" "falco" {
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = "8.0.2"
  namespace        = kubernetes_namespace.falco.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    file("${path.module}/values-falco.yaml")
  ]

  depends_on = [kubernetes_namespace.falco, kubernetes_config_map.falco_custom_rules]
}
