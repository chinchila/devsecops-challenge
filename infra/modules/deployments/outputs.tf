output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "infisical_namespace" {
  value = kubernetes_namespace.infisical.metadata[0].name
}
