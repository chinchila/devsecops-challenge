#!/usr/bin/env bash
# scripts/bootstrap.sh
# End-to-end bootstrap from a fresh GCP account with credits.
# Idempotent - safe to re-run.
#
# Prerequisites:
#   - gcloud CLI authenticated: gcloud auth application-default login
#   - PROJECT_ID environment variable set
#   - cosign, terraform, kubectl, helm installed
#
# Usage:
#   export PROJECT_ID=your-project-id
#   export GITHUB_ORG=your-github-org
#   ./scripts/bootstrap.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${GITHUB_ORG:?Set GITHUB_ORG}"

REGION="${REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-devsecops-challenge}"
TF_BUCKET="${PROJECT_ID}-tf-state"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step()    { echo -e "\n${BLUE}▶ STEP $*${NC}"; }
info()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()     { echo -e "  ${RED}✗ ERROR:${NC} $*"; exit 1; }

step "0 - Validate required tools"
for tool in gcloud terraform kubectl helm cosign htpasswd openssl curl; do
  command -v "$tool" > /dev/null 2>&1 && info "$tool found" || die "$tool not found - install it first"
done

TERRAFORM_VERSION=$(terraform version -json | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])")
info "Terraform $TERRAFORM_VERSION"

step "1 - Configure GCP project"
gcloud config set project "$PROJECT_ID"
MY_IP="$(curl -s ifconfig.me)/32"
info "Your egress IP: $MY_IP (will be used for master_authorized_networks)"

step "2 - Create Terraform state bucket"
if gcloud storage buckets describe "gs://$TF_BUCKET" > /dev/null 2>&1; then
  info "Bucket gs://$TF_BUCKET already exists"
else
  gcloud storage buckets create "gs://$TF_BUCKET" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
  info "Created gs://$TF_BUCKET"
fi

step "3 - Generate Cosign key pair"
if [ -f cosign.key ]; then
  warn "cosign.key already exists - skipping generation"
else
  COSIGN_PASSWORD=$(openssl rand -base64 24)
  COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign generate-key-pair
  info "Key pair generated: cosign.key (private), cosign.pub (public)"
  echo ""
  echo -e "  ${YELLOW}Add these to GitHub Actions Secrets:${NC}"
  echo "  COSIGN_PRIVATE_KEY  = \$(cat cosign.key)"
  echo "  COSIGN_PUBLIC_KEY   = \$(cat cosign.pub)"
  echo "  COSIGN_PASSWORD     = $COSIGN_PASSWORD"
  echo ""
  echo "  Store COSIGN_PASSWORD somewhere safe!"
  echo "$COSIGN_PASSWORD" > .cosign-password.txt
  warn "Password saved to .cosign-password.txt - add to GitHub Secrets and delete this file"
fi

step "4 - Generate Argo CD admin password"
if [ -f .argocd-password.txt ]; then
  warn "Argo CD password already generated - reading from .argocd-password.txt"
  ARGOCD_PASS=$(cat .argocd-password.txt)
else
  ARGOCD_PASS=$(openssl rand -base64 24)
  ARGOCD_HASH=$(htpasswd -nbBC 10 '' "$ARGOCD_PASS" | tr -d ':\n' | sed 's/^!//')
  echo "$ARGOCD_PASS" > .argocd-password.txt
  echo "$ARGOCD_HASH" > .argocd-hash.txt
  info "Password saved to .argocd-password.txt"
fi
ARGOCD_HASH=$(cat .argocd-hash.txt 2>/dev/null || \
  htpasswd -nbBC 10 '' "$ARGOCD_PASS" | tr -d ':\n' | sed 's/^!//')

warn ".argocd-password.txt and .argocd-hash.txt are in .gitignore - do not commit"

step "5 - Generate Infisical DB password"
if [ -f .infisical-db-password.txt ]; then
  warn "DB password already generated"
  INFISICAL_DB_PASS=$(cat .infisical-db-password.txt)
else
  INFISICAL_DB_PASS=$(openssl rand -base64 24)
  echo "$INFISICAL_DB_PASS" > .infisical-db-password.txt
  info "DB password saved to .infisical-db-password.txt"
fi

step "5b - Generate Infisical ENCRYPTION_KEY and AUTH_SECRET"
if [ -f .infisical-app-secrets.txt ]; then
  warn "Infisical app secrets already generated"
  INFISICAL_ENCRYPTION_KEY=$(grep ENCRYPTION_KEY .infisical-app-secrets.txt | cut -d= -f2)
  INFISICAL_AUTH_SECRET=$(grep AUTH_SECRET .infisical-app-secrets.txt | cut -d= -f2)
else
  INFISICAL_ENCRYPTION_KEY=$(openssl rand -hex 16)
  INFISICAL_AUTH_SECRET=$(openssl rand -base64 32)
  printf "ENCRYPTION_KEY=%s\nAUTH_SECRET=%s\n" "$INFISICAL_ENCRYPTION_KEY" "$INFISICAL_AUTH_SECRET" > .infisical-app-secrets.txt
  info "Infisical app secrets saved to .infisical-app-secrets.txt"
fi

step "6 - Patch manifests with your GitHub org"
sed -i "s|chinchila|$GITHUB_ORG|g" k8s/argocd/applications.yaml k8s/argocd/projects.yaml
sed -i "s|chinchila|$GITHUB_ORG|g" .github/workflows/ci.yaml
info "Patched GitHub org to: $GITHUB_ORG"

step "7 - Terraform init + apply"
cd infra

terraform init \
  -backend-config="bucket=$TF_BUCKET" \
  -backend-config="prefix=devsecops-challenge/state"

terraform apply \
  -var="project_id=$PROJECT_ID" \
  -var="region=$REGION" \
  -var="cluster_name=$CLUSTER_NAME" \
  -var="master_authorized_cidr=$MY_IP" \
  -var="image_registry=ghcr.io/$GITHUB_ORG/devsecops-challenge" \
  -var="argocd_admin_password_bcrypt=$ARGOCD_HASH" \
  -var="infisical_db_password=$INFISICAL_DB_PASS" \
  -var="infisical_encryption_key=$INFISICAL_ENCRYPTION_KEY" \
  -var="infisical_auth_secret=$INFISICAL_AUTH_SECRET" \
  -auto-approve

KUBECONFIG_CMD=$(terraform output -raw kubeconfig_command)
cd ..
info "Terraform apply complete"

step "8 - Configure kubeconfig"
eval "$KUBECONFIG_CMD"
kubectl cluster-info
info "kubeconfig configured"

step "9 - Apply security manifests"
kubectl apply -f k8s/security/networkpolicies/policies.yaml
kubectl apply -f k8s/security/istio-policies.yaml
kubectl apply -f k8s/security/istio-gateway.yaml
kubectl apply -f k8s/security/falco/custom-rules-configmap.yaml
kubectl apply -f k8s/security/prometheus-istio-scrape.yaml
info "Security manifests applied"

step "10 - Create Argo CD Projects and Applications"
kubectl apply -f k8s/argocd/projects.yaml
kubectl apply -f k8s/argocd/applications.yaml
info "Argo CD Applications created"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Bootstrap complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Add GitHub Actions Secrets (from cosign + Argo CD steps above):"
echo "       COSIGN_PRIVATE_KEY, COSIGN_PUBLIC_KEY, COSIGN_PASSWORD"
echo "       GIT_BOT_TOKEN  (PAT with repo:write scope)"
echo ""
echo "  2. Bootstrap Infisical (one-time manual step):"
echo "       make argocd-port-forward &"
echo "       kubectl port-forward svc/infisical -n infisical 8888:8080 &"
echo "       # Open http://localhost:8888 and create project + JWT_SECRET"
echo "       # Then create Machine Identity and run:"
echo "       for ns in service-1 service-2 service-3; do"
echo "         kubectl create secret generic infisical-machine-identity \\"
echo "           --from-literal=clientId=<ID> \\"
echo "           --from-literal=clientSecret=<SECRET> \\"
echo "           -n \$ns"
echo "       done"
echo "       kubectl apply -f k8s/security/infisical-secrets.yaml"
echo ""
echo "  3. Push code to trigger the CI pipeline:"
echo "       git push origin main"
echo "       # CI builds, scans, signs, and updates manifests"
echo "       # Argo CD auto-syncs the new image tags"
echo ""
echo "  4. Run validations:"
echo "       make validate-all"
echo ""
echo "  5. Run Falco demo:"
echo "       ./scripts/falco-demo.sh"
echo ""
echo "  Argo CD password: $(cat .argocd-password.txt)"
echo "  Argo CD UI:       make argocd-port-forward"
