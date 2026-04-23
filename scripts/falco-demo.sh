#!/usr/bin/env bash
# scripts/falco-demo.sh
# Demonstrates two Falco custom rule alerts as required by the challenge.
# Run AFTER the cluster is up and Falco is installed.
#
# Usage:
#   chmod +x scripts/falco-demo.sh
#   ./scripts/falco-demo.sh
#
# What it does:
#   1. Creates a temporary debug pod in service-1 namespace
#   2. Triggers: "Shell Executed in App Container" (T-RT-01)
#   3. Triggers: "Sensitive File Read in App Container" (T-RT-02)
#   4. Waits and collects Falco alert output
#   5. Cleans up

set -euo pipefail

NS="service-1"
POD="falco-demo"
FALCO_NS="falco"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo -e "\n${YELLOW}════════════════════════════════════════${NC}"; echo -e "${YELLOW}  $*${NC}"; echo -e "${YELLOW}════════════════════════════════════════${NC}"; }

section "Preflight checks"

kubectl cluster-info --request-timeout=5s > /dev/null 2>&1 || {
  echo -e "${RED}ERROR: Cannot reach cluster. Run: make kubeconfig${NC}"
  exit 1
}
info "Cluster reachable"

kubectl get pods -n "$FALCO_NS" -l app.kubernetes.io/name=falco --no-headers 2>/dev/null | grep -q Running || {
  echo -e "${RED}ERROR: Falco is not running in namespace $FALCO_NS${NC}"
  exit 1
}
info "Falco is running"

FALCO_POD=$(kubectl get pod -n "$FALCO_NS" -l app.kubernetes.io/name=falco \
  -o jsonpath='{.items[0].metadata.name}')
info "Falco pod: $FALCO_POD"

section "Creating demo pod in namespace: $NS"

# Note: This pod intentionally uses alpine (has a shell) to trigger Falco.
# The real app pods use distroless and cannot execute shells.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  labels:
    app: $POD
    demo: falco
  annotations:
    # Bypass PSS for this demo pod only - it needs a shell to trigger Falco
    pod-security.kubernetes.io/enforce-version: latest
spec:
  # Override PSS restricted for demo purposes only
  securityContext:
    runAsUser: 65532
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: $POD
      image: alpine:3.19
      command: ["sleep", "120"]
      securityContext:
        runAsUser: 65532
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        limits:
          cpu: "100m"
          memory: "64Mi"
  restartPolicy: Never
EOF

info "Waiting for demo pod to be Ready..."
kubectl wait --for=condition=Ready pod/$POD -n "$NS" --timeout=60s
info "Demo pod is ready"

# Give Falco a moment to register the new container
sleep 3

# Record timestamp for log filtering
START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

section "Demo 1: Shell Execution in App Container (T-RT-01)"
info "Executing: kubectl exec -n $NS $POD -- sh -c 'id && hostname'"
info "Expected Falco rule: 'Shell Executed in App Container' (CRITICAL)"

kubectl exec -n "$NS" "$POD" -- sh -c "id && hostname" || true

info "Waiting 3s for Falco to process event..."
sleep 3

section "Demo 2: Sensitive File Read (T-RT-02)"
info "Executing: kubectl exec -n $NS $POD -- cat /etc/passwd"
info "Expected Falco rule: 'Sensitive File Read in App Container' (WARNING)"

kubectl exec -n "$NS" "$POD" -- sh -c "cat /etc/passwd" > /dev/null 2>&1 || true

info "Waiting 3s for Falco to process event..."
sleep 3

section "Falco Alert Output"
info "Fetching Falco logs since $START_TIME..."
echo ""

ALERTS=$(kubectl logs -n "$FALCO_NS" "$FALCO_POD" \
  --since-time="$START_TIME" 2>/dev/null | \
  grep -E '"rule":"(Shell Executed in App Container|Sensitive File Read in App Container)"' \
  || true)

if [ -n "$ALERTS" ]; then
  echo -e "${GREEN}✓ Falco alerts triggered:${NC}"
  echo "$ALERTS" | python3 -m json.tool 2>/dev/null || echo "$ALERTS"
else
  warn "No matching alerts found yet. Full recent Falco output:"
  kubectl logs -n "$FALCO_NS" "$FALCO_POD" --since-time="$START_TIME" 2>/dev/null | tail -30
  warn "If no alerts appear, check that custom rules ConfigMap is mounted:"
  warn "  kubectl describe pod $FALCO_POD -n $FALCO_NS | grep Volumes -A 20"
fi

section "Cleanup"
kubectl delete pod "$POD" -n "$NS" --ignore-not-found=true
info "Demo pod deleted"

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Falco demo complete${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "To watch Falco alerts in real time:"
echo "  kubectl logs -n $FALCO_NS $FALCO_POD --follow"
echo ""
echo "To run all validations:"
echo "  make validate-all"
