# devsecops-challenge

Implementação de postura de segurança em profundidade sobre GKE Standard com Istio, Argo CD, Infisical, Falco, Trivy e Cosign.

---

## Decisões de implementação

### Por que Go?

- Binário estático único: com `CGO_ENABLED=0` - elimina dependências de libc e simplifica o `Dockerfile` multi-stage.
- Imagem distroless: sem shell, sem package manager, sem libc. Diminui a superfície de ataque.
- Footprint mínimo: o binário final tem uns 10MB. Menos camadas = menos CVEs = menos ruído no Trivy.
- Timeouts explícitos no `http.Server`: `ReadTimeout`, `WriteTimeout` e `IdleTimeout` são obrigatórios em serviços expostos - Node.js e Python exigem configuração extra; Go obriga a pensar nisso.

### Por que Infisical?

A stack de produção já usa Infisical self-hosted. A escolha foi feita para maximizar fidelidade com o ambiente real, abaixo uma comparação com GCP Secret Manager:

| Critério | Infisical self-hosted | GCP Secret Manager |
|---|---|---|
| Integração com o stack existente | ✓ já em uso | Requer migração |
| Custo | Incluído no cluster | $0.06/secret, $0.03/10k ops |
| Auditado | ✓ | ✓ |
| Vendor lock-in | Baixo (self-hosted) | Alto (GCP-only) |
| Operação | Maior overhead | Managed |

Trade-offs: Infisical self-hosted adiciona um componente stateful (PostgreSQL) que é um ponto de falha. Ver `R-05` no `THREAT_MODEL.md`.

### Por que `modern_ebpf` no Falco (e não `kmod`)?

GKE Standard com `ADVANCED_DATAPATH` (eBPF/Cilium) pode ter conflitos com o driver `kmod` do Falco. O `modern_ebpf` não exige módulo de kernel e funciona com acesso normal ao syscall interface - recomendado para GKE Standard com canal RAPID.

---

## Arquitetura de segurança por camada

```
┌──────────────────────────────────────────────────────────────────┐
  SUPPLY CHAIN                                                    
  Gitleaks → Checkov → Trivy (prod + insecure) → Cosign sign     
└──────────────────────────────┬───────────────────────────────────┘
                               │ merge to main
┌──────────────────────────────▼───────────────────────────────────┐
  GITOPS                                                          
  Argo CD syncs k8s/base/* → único caminho de deploy             
└──────────────────────────────┬───────────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────────┐
  REDE (L3/L4 + L7)                                               
  NetworkPolicy default-deny + Istio mTLS STRICT                 
  AuthorizationPolicy (JWT + SPIFFE principal + DENY lateral)    
└──────────────────────────────┬───────────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────────┐
  RUNTIME                                                         
  PSS restricted enforce + non-root + readOnlyFS + drop ALL      
  Falco (5 regras custom) + seccompProfile RuntimeDefault        
└──────────────────────────────┬───────────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────────┐
  IDENTIDADE                                                      
  Workload Identity (GKE_METADATA) + Infisical Secrets Operator  
  automountServiceAccountToken: false                            
└──────────────────────────────────────────────────────────────────┘
```

---

## Pré-requisitos

- Conta GCP
- `gcloud` CLI autenticado (`gcloud auth application-default login`)
- `terraform` >= 1.7
- `kubectl`, `helm`, `cosign`, `docker`
- Repositório GitHub (para CI e Argo CD)

---

## Passo a passo reproduzível do zero

### 0. Clone e configure o repositório

```bash
git clone https://github.com/Chinchila/devsecops-challenge
cd devsecops-challenge

sed -i 's|Chinchila|<seu user github>|g' k8s/argocd/applications.yaml
```

### 1. Crie o bucket de estado do Terraform

```bash
export PROJECT_ID=<seu-project-id>
export REGION=us-central1
export TF_BUCKET="${PROJECT_ID}-tf-state"

gcloud storage buckets create "gs://${TF_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access
```

### 2. Gere as chaves Cosign

```bash
cosign generate-key-pair

# Adicione como GitHub Secrets:
# COSIGN_PRIVATE_KEY = $(cat cosign.key)
# COSIGN_PUBLIC_KEY  = $(cat cosign.pub)
# COSIGN_PASSWORD    = <senha escolhida>

echo "cosign.key" >> .gitignore
```

### 3. Configure o Argo CD admin password

```bash
# Gere o hash bcrypt
ARGOCD_PASS=$(openssl rand -base64 32)
ARGOCD_HASH=$(htpasswd -nbBC 10 '' "${ARGOCD_PASS}" | tr -d ':\n' | sed 's/^!//')
echo "Guarde esta senha em um password manager: ${ARGOCD_PASS}"
```

### 4. Provisionamento do cluster

```bash
cd infra

# Descubra seu IP de saída para restringir o API server
# dependendo da empresa e config do cluster pode deixar
# 0.0.0.0/0 ou os ips de saída da VPN se usar
MY_IP=$(curl -s ifconfig.me)/32
INFISICAL_PASS=$(openssl rand -base64 24)

echo "Guarde esta senha em um password manager: ${INFISICAL_PASS}"

terraform init \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="prefix=devsecops-challenge/state"

terraform apply \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}" \
  -var="master_authorized_cidr=${MY_IP}" \
  -var="image_registry=ghcr.io/<seu-org>/devsecops-challenge" \
  -var="argocd_admin_password_bcrypt=${ARGOCD_HASH}" \
  -var="infisical_db_password=${INFISICAL_PASS}"
```

### 5. Configure kubeconfig

```bash
$(terraform output -raw kubeconfig_command)
```

### 6. Configure o Infisical

```bash
# Port-forward para acessar o Infisical UI
kubectl port-forward svc/infisical-infisical-standalone-infisical -n infisical 8888:8080 &

# Acesse http://localhost:8888 e:
# 1. Crie uma conta admin
# 2. Crie um projeto chamado "devsecops-challenge"
# 3. Adicione a variável JWT_SECRET no ambiente "prod"
# 4. Crie uma Machine Identity com acesso de leitura ao projeto
# 5. Copie o clientId e clientSecret, recomendado: salvar 

# Crie os secrets de autenticação do Infisical em cada namespace
for ns in service-1 service-2 service-3; do
  kubectl create secret generic infisical-machine-identity \
    --from-literal=clientId=<CLIENT_ID> \
    --from-literal=clientSecret=<CLIENT_SECRET> \
    -n ${ns}
done

# Aplique os InfisicalSecret CRDs (Argo CD fará isso em prod - aqui é bootstrap)
kubectl apply -f k8s/security/infisical-secrets.yaml
```

### 7. Aplique as políticas de segurança

```bash
# NetworkPolicy + Istio AuthorizationPolicy + Falco rules
kubectl apply -f k8s/security/networkpolicies/policies.yaml
kubectl apply -f k8s/security/istio-policies.yaml
kubectl apply -f k8s/security/falco/custom-rules-configmap.yaml
```

### 8. Configure o Argo CD e a bootstrap das Applications

```bash
# Port-forward para o Argo CD
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Login
argocd login localhost:8080 \
  --username admin \
  --password "${ARGOCD_PASS}" \
  --insecure

# Aplique as Applications
kubectl apply -f k8s/argocd/applications.yaml

# Verifique o sync
argocd app list
argocd app sync service-1 service-2 service-3
```

### 9. Build e push da imagem inicial

```bash
# O CI faz isso automaticamente; para bootstrap manual:
docker build -t ghcr.io/chinchila/devsecops-challenge:initial .
docker push ghcr.io/chinchila/devsecops-challenge:initial

# Atualize as tags nos manifestos e faça commit → Argo CD sincroniza
```

---

## Validação de segurança

### Supply chain

```bash
# Verificar assinatura Cosign
cosign verify --key cosign.pub \
  ghcr.io/<seu-org>/devsecops-challenge:<sha>

# Verificar que insecure.Dockerfile tem CVEs críticos
docker build -f insecure.Dockerfile -t test-insecure .
trivy image --severity CRITICAL --exit-code 1 test-insecure
# Esperado: exit code 1 (CVEs encontrados)

# Verificar que prod Dockerfile não tem CVEs críticos
docker build -f Dockerfile -t test-prod .
trivy image --severity CRITICAL --exit-code 1 test-prod
# Esperado: exit code 0
```

### Rede e Istio

```bash
# Verificar mTLS STRICT ativo
istioctl x describe pod -n service-1 $(kubectl get pod -n service-1 -o name | head -1)

# Testar bloqueio lateral: service-1 NÃO deve conseguir chamar service-3
kubectl exec -n service-1 deploy/service-1 -c service-1 -- \
  wget -qO- http://service-3.service-3.svc.cluster.local:8080/ 2>&1
# Esperado: Connection refused ou RBAC error

# Testar caminho permitido: service-1 -> service-2
kubectl exec -n service-1 deploy/service-1 -c service-1 -- \
  wget -qO- http://service-2.service-2.svc.cluster.local:8080/
# Esperado: {"service":"2"}
```

### Runtime hardening

```bash
# Verificar PSS restricted
kubectl get ns service-1 -o jsonpath='{.metadata.labels}'
# Esperado: pod-security.kubernetes.io/enforce=restricted

# Verificar que containers rodam como não-root
kubectl get pod -n service-1 -o jsonpath='{.items[0].spec.containers[0].securityContext}'

# Executar kube-bench
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench
```

### Falco - demonstração de alertas

```bash
# Alerta 1: Shell execution (distroless não tem shell - use uma imagem de debug)
# Para demonstração, temporariamente use um pod com shell:
kubectl run debug-pod --image=alpine --namespace=service-1 \
  --overrides='{"spec":{"securityContext":{"runAsUser":65532}}}' \
  -- sleep 3600

kubectl exec -n service-1 debug-pod -- sh -c "id"
# Falco deve disparar: "Shell executed in app container"

# Alerta 2: Leitura de /etc/passwd
kubectl exec -n service-1 debug-pod -- cat /etc/passwd
# Falco deve disparar: "Sensitive file read in app container"

# Verificar alertas do Falco
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=50 | grep -E "CRITICAL|WARNING"

# Cleanup
kubectl delete pod debug-pod -n service-1
```

### Secrets

```bash
# Verificar que JWT_SECRET não aparece em plaintext no repositório
git log --all --full-history -- '*.yaml' '*.tf' '*.env' | \
  xargs grep -l "JWT_SECRET" 2>/dev/null | \
  grep -v "deployment.yaml" | \
  grep -v "infisical-secrets.yaml"
# Esperado: nenhum resultado (apenas referências ao nome da key, nunca ao valor)

# Verificar que o secret foi sincronizado pelo Infisical operator
kubectl get secret app-secrets -n service-1 -o jsonpath='{.data.JWT_SECRET}' | \
  base64 -d | wc -c
# Esperado: > 0 (secret presente, mas valor não exibido aqui)
```

### GitOps

```bash
# Verificar que Argo CD é o único responsável pelo estado
argocd app get service-1 --show-operation

# Simular drift: altere um label manualmente
kubectl label deploy/service-1 -n service-1 test=manual-change

# Argo CD deve reverter em < 3 minutos (selfHeal: true)
kubectl get deploy/service-1 -n service-1 --watch
```

---

## Análise crítica - o que ficou de fora e por quê

**Binary Authorization:** Requer um attestor (Cloud Build ou customizado) para assinar attestations de build. A infraestrutura de attestation vai além do escopo do desafio. Mitigação parcial: Cosign + Argo CD como source of truth. Documentado como `R-02`.

**master_authorized_networks restrito:** Em ambiente de demonstração, o IP de egresso não é fixo. Em produção, deve ser o IP da VPN/bastion corporativa. Variável parametrizada - substitua `master_authorized_cidr` pelo seu IP real.

**Cloud Armor WAF:** Regras OWASP CRS e rate limiting por IP requerem configuração específica por aplicação. O desafio instrui explicitamente a não cobrir Cloud Armor avançado.

**Falco como prevention (não só detection):** Falco não tem capacidade de bloquear syscalls nativamente (isso é domínio do seccomp/AppArmor). A combinação PSS + NetworkPolicy + Falco fornece prevenção (PSS/NetPol) + detecção (Falco). Runtime prevention completa exigiria eBPF LSM ou AppArmor profiles customizados.

**Multi-tenancy no Argo CD:** Uma única instância de Argo CD gerencia todos os namespaces. Em produção com múltiplos times, considerar Argo CD Projects com RBAC granular ou instâncias separadas.
