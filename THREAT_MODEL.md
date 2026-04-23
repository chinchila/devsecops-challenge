# Threat Model - devsecops-challenge

## Metodologia

STRIDE aplicado por camada, com mapeamento explícito de atores → vetores → ameaças → controles → riscos residuais. Cada controle implementado referencia o ID de ameaça correspondente.

---

## 1. Superfície de Ataque

### Pontos de entrada externos

| Ponto de entrada | Protocolo | Exposição |
|---|---|---|
| Istio Ingress Gateway (service-1) | HTTPS + JWT | Internet → cluster |
| Istio Ingress Gateway (service-3) | HTTPS + JWT | Internet → cluster |
| GKE API Server | HTTPS | `master_authorized_networks` - padrão: `0.0.0.0/0` (risco documentado) |
| Cloud Armor (ingress) | L7 | Configuração permissiva por padrão (risco documentado) |

### Pontos de entrada internos (lateral movement)

| Ponto de entrada | Vetor |
|---|---|
| Metadata server GCE (`169.254.169.254`) | SSRF de qualquer pod para obter tokens de SA do node |
| API server via token de ServiceAccount | Pod comprometido lendo secrets ou criando workloads |
| Comunicação entre namespaces | Ausência de NetworkPolicy ou AuthorizationPolicy |
| Infisical (`infisical.infisical.svc`) | Acesso não autorizado ao operator ou à API interna |
| Imagem comprometida no registry | Supply chain - imagem com backdoor ou CVE crítico |

---

## 2. Atores e Vetores

### Ator externo - Atacante de internet

**Perfil:** Adversário remoto sem acesso inicial ao cluster.

| Vetor | Descrição |
|---|---|
| JWT forjado / replay | Tenta acessar service-1 ou service-3 com token expirado, mal assinado ou de outro issuer |
| Exploração de CVE em container | Explora vulnerabilidade conhecida na imagem base para RCE dentro do pod |
| Supply chain attack | Submete PR com dependência maliciosa ou imagem com backdoor |
| Abuso de Cloud Armor permissivo | Envia requests malformados, payloads oversized, ou ataques L7 sem filtragem |

### Ator interno - Pod comprometido

**Perfil:** Processo em execução dentro do cluster com comprometimento parcial (e.g., RCE via CVE na aplicação).

| Vetor | Descrição |
|---|---|
| Lateral movement via rede | Pod de service-1 tentando alcançar service-3 diretamente |
| Roubo de credenciais GCP | SSRF para metadata server (`169.254.169.254`) para obter token do SA do node |
| Escalada via API server | Uso do token do ServiceAccount para criar pods, ler secrets de outros namespaces |
| Exfiltração de JWT_SECRET | Leitura de variáveis de ambiente via `/proc/*/environ` ou de secrets Kubernetes |
| Persistência via escrita em filesystem | Tentativa de escrita em paths fora de `/tmp` em containers com readOnlyRootFilesystem |

---

## 3. Ameaças Identificadas por Camada

### Supply Chain

| ID | Ameaça | Impacto | Probabilidade |
|---|---|---|---|
| T-SC-01 | Imagem base com CVEs críticos em produção | Crítico - RCE no container | Alta (imagens desatualizadas são comuns) |
| T-SC-02 | Imagem não assinada substituída no registry (MITM ou registry comprometido) | Crítico - execução de código arbitrário | Média |
| T-SC-03 | Credenciais hardcoded no repositório (API keys, JWT_SECRET, cosign private key) | Crítico - comprometimento de todos os ambientes | Alta (erro humano frequente) |
| T-SC-04 | Misconfiguration crítica em IaC mergeada sem revisão | Alto - exposure de cluster ou dados | Média |

### Rede

| ID | Ameaça | Impacto | Probabilidade |
|---|---|---|---|
| T-NET-01 | Comunicação lateral não autorizada (service-1 → service-3) | Alto - bypass de controles de acesso | Alta (sem policy = permitido) |
| T-NET-02 | Tráfego em plaintext entre pods (sem mTLS) | Alto - interceptação de dados sensíveis | Alta (Istio em PERMISSIVE mode) |
| T-NET-03 | Acesso direto ao GKE API server de qualquer IP | Crítico - administração irrestrita do cluster | Média (requer credenciais) |
| T-NET-04 | Egress não autorizado de container para C2 externo | Crítico - exfiltração, beacon para C2 | Baixa (requer comprometimento inicial) |

### Runtime

| ID | Ameaça | Impacto | Probabilidade |
|---|---|---|---|
| T-RT-01 | Execução de shell dentro de container da aplicação | Crítico - container escape, reconhecimento | Baixa (requer RCE inicial) |
| T-RT-02 | Leitura de arquivos sensíveis (`/etc/passwd`, `/proc/*/environ`) | Alto - roubo de credenciais, JWT_SECRET | Média (se container comprometido) |
| T-RT-03 | Escrita em filesystem read-only para persistência | Alto - backdoor persistente | Baixa (requer escalonamento) |
| T-RT-04 | Container rodando como root | Crítico - qualquer LPE no kernel → root no node | Média (default em muitas imagens) |
| T-RT-05 | Capabilities Linux excessivas (NET_ADMIN, SYS_ADMIN) | Crítico - container escape | Média (default em K8s sem PSS) |

### Identidade

| ID | Ameaça | Impacto | Probabilidade |
|---|---|---|---|
| T-ID-01 | SSRF para metadata server (`169.254.169.254`) | Crítico - token do SA do node com amplos poderes IAM | Alta (link-local acessível por padrão) |
| T-ID-02 | Token de ServiceAccount Kubernetes com permissões excessivas | Alto - leitura de secrets de outros namespaces, criação de pods | Alta (RBAC permissivo é comum) |
| T-ID-03 | JWT_SECRET comprometido (via log, env leak ou repositório) | Crítico - geração de tokens arbitrários | Média |
| T-ID-04 | Admin password do Argo CD em plaintext no repositório | Crítico - deploy arbitrário no cluster | Alta (erro de configuração frequente) |

---

## 4. Controles Implementados

Cada controle referencia as ameaças que mitiga.

### Supply Chain

| Controle | Ameaças mitigadas | Implementação |
|---|---|---|
| Trivy scan bloqueante no CI (prod Dockerfile) | T-SC-01 | `.github/workflows/ci.yaml` - gate `scan-prod-image` |
| Trivy scan bloqueante no CI (insecure.Dockerfile) | T-SC-01 | `.github/workflows/ci.yaml` - gate `scan-insecure-image` (expected fail) |
| Cosign signing da imagem de produção | T-SC-02 | `.github/workflows/ci.yaml` - gate `sign-image`; chave privada em GitHub Secrets |
| Gitleaks bloqueante (full history scan) | T-SC-03 | `.github/workflows/ci.yaml` - gate `secret-detection` |
| Checkov bloqueante (Terraform + YAML) | T-SC-04 | `.github/workflows/ci.yaml` - gate `iac-scanning` |
| Imagem distroless (sem shell, sem package manager) | T-SC-01, T-RT-01 | `Dockerfile` - `gcr.io/distroless/static-debian12:nonroot` |
| JWT_SECRET e cosign key gerenciados via Infisical | T-SC-03, T-ID-03 | `k8s/security/infisical-secrets.yaml` |

### Rede

| Controle | Ameaças mitigadas | Implementação |
|---|---|---|
| NetworkPolicy default-deny + allowlist mínimo | T-NET-01, T-NET-04 | `k8s/security/networkpolicies/policies.yaml` |
| Istio mTLS STRICT (PeerAuthentication global) | T-NET-02 | `k8s/security/istio-policies.yaml` |
| AuthorizationPolicy com DENY explícito (service-1, service-2 → service-3) | T-NET-01 | `k8s/security/istio-policies.yaml` - `deny-lateral-movement` |
| RequestAuthentication JWT em service-1 e service-3 | T-NET-01 (external) | `k8s/security/istio-policies.yaml` |
| `master_authorized_networks` - variável parametrizada (TODO: restringir) | T-NET-03 | `infra/modules/gke/main.tf` - `var.master_authorized_cidr` |

### Runtime

| Controle | Ameaças mitigadas | Implementação |
|---|---|---|
| Pod Security Standards `restricted` (enforce) | T-RT-04, T-RT-05 | Labels nos 3 namespaces da aplicação (Terraform `deployments/main.tf`) |
| `runAsNonRoot: true`, `runAsUser: 65532` | T-RT-04 | Todos os Deployments + distroless nonroot |
| `readOnlyRootFilesystem: true` | T-RT-03 | Todos os Deployments |
| `capabilities.drop: [ALL]` | T-RT-05 | Todos os Deployments |
| `seccompProfile: RuntimeDefault` | T-RT-01, T-RT-05 | Todos os Deployments |
| Resource limits (CPU + memory) | DoS interno | Todos os Deployments |
| Falco - rule: Shell Executed in App Container | T-RT-01 | `k8s/security/falco/custom-rules-configmap.yaml` |
| Falco - rule: Sensitive File Read | T-RT-02 | `k8s/security/falco/custom-rules-configmap.yaml` |
| Falco - rule: Write Attempt on Read-Only Filesystem | T-RT-03 | `k8s/security/falco/custom-rules-configmap.yaml` |
| Falco - rule: GCE Metadata Server Access | T-ID-01 | `k8s/security/falco/custom-rules-configmap.yaml` |
| Falco - rule: Unexpected Outbound Connection | T-NET-04 | `k8s/security/falco/custom-rules-configmap.yaml` |
| `disable-legacy-endpoints: "true"` nos nodes | T-ID-01 | `infra/modules/gke/main.tf` - node metadata |
| Workload Identity (`GKE_METADATA` mode) | T-ID-01, T-ID-02 | Node pool config + GCP SA bindings |

### Identidade

| Controle | Ameaças mitigadas | Implementação |
|---|---|---|
| Infisical Secrets Operator (JWT_SECRET via CRD) | T-ID-03, T-SC-03 | `k8s/security/infisical-secrets.yaml` |
| Cosign private key em GitHub Secrets (não no repo) | T-SC-03 | CI workflow - `COSIGN_PRIVATE_KEY` secret |
| `automountServiceAccountToken: false` | T-ID-02 | Todos os Deployments |
| Argo CD admin password como bcrypt hash via variável Terraform | T-ID-04 | `infra/variables.tf` - `argocd_admin_password_bcrypt` |
| RBAC mínimo para ServiceAccounts da aplicação | T-ID-02 | Nenhuma ClusterRoleBinding criada para os SAs da app |

### GitOps / Pipeline

| Controle | Ameaças mitigadas | Implementação |
|---|---|---|
| Argo CD como único mecanismo de deploy | T-SC-02 (deriva de manifesto) | `kubectl apply` direto não é usado; CI só atualiza manifests no git |
| `selfHeal: true` no Argo CD | Deriva de configuração | `k8s/argocd/applications.yaml` |
| Pipeline bloqueante - nenhum gate em report-only | T-SC-01, T-SC-03, T-SC-04 | Todos os gates usam `exit-code: 1` ou `soft_fail: false` |

---

## 5. Riscos Residuais

| ID | Risco | Justificativa para não cobertura |
|---|---|---|
| R-01 | `master_authorized_networks` aberto (`0.0.0.0/0`) | IP egress do operador não é fixo neste ambiente de demonstração. Em produção, deve ser restringido ao IP corporativo ou VPN. Documentado como `# TODO: restrict in production` em `variables.tf`. |
| R-02 | Binary Authorization desabilitada | Requer infraestrutura de attestation (Cloud Build ou attestor customizado) que está fora do escopo do desafio. Risco mitigado parcialmente pela assinatura Cosign + Argo CD como source of truth. Documentado como `CKV_GCP_25` no Checkov skip. |
| R-03 | Cloud Armor em modo permissivo | Regras WAF avançadas (OWASP CRS, rate limiting por IP) não foram configuradas. O desafio instrui explicitamente a não cobrir Cloud Armor avançado. Mitigado parcialmente pelo JWT validation no Istio. |
| R-04 | Falco não bloqueia - apenas alerta | Falco é um sistema de detecção, não de prevenção. Um ataque bem-sucedido dentro de uma janela de resposta de minutos pode causar dano antes de ser interrompido. Mitigação: combinar com NetworkPolicy (L3/L4 blocking) e PSS (prevenção de root). |
| R-05 | Infisical self-hosted como single point of failure | Se o Infisical ficar indisponível, novos pods não conseguem resolver secrets e falham no startup. `resyncInterval: 60` mitiga para pods já em execução (secret cacheado no Kubernetes Secret), mas não para cold starts pós-falha. |
| R-06 | Sem auditoria de acesso ao Infisical | Logs de quais serviços acessaram quais secrets não estão sendo coletados centralmente neste setup. Em produção, integrar com Cloud Logging. |
| R-07 | Node-level breakout não detectado pelo Falco | Exploits de kernel (e.g., Dirty COW, Dirty Pipe) que escalam diretamente no host não são cobertos por regras de namespace Kubernetes. Mitigação parcial: Shielded Nodes + Secure Boot + GKE RAPID channel (patches rápidos). |
