#!/usr/bin/env bash
# 테스트 환경 전체 배포 스크립트
# 실행: bash scripts/deploy.sh
set -euo pipefail

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"  # export SLACK_WEBHOOK=https://hooks.slack.com/... 으로 주입
REGION="ap-northeast-2"
ACCOUNT_ID="906336681755"
CLUSTER_NAME="point-main-eks"
NAMESPACE="point"
TF_BOOTSTRAP="infra/terraform/bootstrap/aws"
TF_MAIN="infra/terraform/envs/aws-main"
BACKEND_DIR="../point-backend"
ARGOCD_VERSION="v2.14.0"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

slack() {
  local msg="$1"
  [ -z "$SLACK_WEBHOOK" ] && return 0
  curl -s -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    --data "{\"text\":\"$msg\"}" > /dev/null
}

# 실패 시 Slack 알림
trap 'slack ":x: *point-platform 배포 실패* — 단계를 확인하세요 ($(date +\"%H:%M\"))"' ERR

# ── 1. Terraform bootstrap (S3 state bucket) ─────────────────────────────────
log "1/8  Terraform bootstrap: S3 state bucket"
cd "$TF_BOOTSTRAP"
terraform init -input=false
terraform apply -input=false -auto-approve \
  -var "bucket_name=point-platform-tfstate-${ACCOUNT_ID}"
cd - > /dev/null

# ── 2. Terraform aws-main (VPC + EKS + Aurora + ECR) ─────────────────────────
log "2/8  Terraform aws-main: VPC / EKS / Aurora / ECR"
cd "$TF_MAIN"
terraform init -input=false
terraform apply -input=false -auto-approve
AURORA_ENDPOINT=$(terraform output -raw aurora_endpoint)
AURORA_SECRET_ARN=$(terraform output -raw aurora_secret_arn)
ECR_MONOLITH=$(terraform output -raw ecr_monolith_url)
ECR_EVENT=$(terraform output -raw ecr_event_service_url)
cd - > /dev/null

# ── 3. kubeconfig ─────────────────────────────────────────────────────────────
log "3/8  Updating kubeconfig for EKS cluster"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

# ── 4. ArgoCD 설치 ────────────────────────────────────────────────────────────
log "4/8  Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
log "     Waiting for ArgoCD server to be ready..."
kubectl rollout status deploy/argocd-server -n argocd --timeout=180s

# ── 5. Aurora DB 시크릿 → K8s Secret 생성 ────────────────────────────────────
log "5/8  Creating monolith-db K8s secret from Secrets Manager"
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$AURORA_SECRET_ARN" \
  --region "$REGION" \
  --query SecretString --output text)

DB_USER=$(echo "$SECRET_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['username'])")
DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['password'])")
DB_URL="jdbc:postgresql://${AURORA_ENDPOINT}:5432/point"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic monolith-db \
  --namespace "$NAMESPACE" \
  --from-literal=DB_URL="$DB_URL" \
  --from-literal=DB_USERNAME="$DB_USER" \
  --from-literal=DB_PASSWORD="$DB_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 6. Docker 이미지 빌드 & ECR 푸시 ─────────────────────────────────────────
log "6/8  Building and pushing Docker images"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

cd "$BACKEND_DIR"
for MODULE in monolith event-service; do
  log "     Building $MODULE..."
  docker build -f "${MODULE}/Dockerfile" -t "app-${MODULE}:0.1.0" .
  case "$MODULE" in
    monolith)      ECR_URL="$ECR_MONOLITH" ;;
    event-service) ECR_URL="$ECR_EVENT" ;;
  esac
  docker tag "app-${MODULE}:0.1.0" "${ECR_URL}:0.1.0"
  docker push "${ECR_URL}:0.1.0"
done
cd - > /dev/null

# ── 7. ArgoCD 앱 적용 ────────────────────────────────────────────────────────
log "7/8  Applying ArgoCD apps"
kubectl apply -f k8s/argocd/aws/apps.yaml

# ── 8. 파드 Ready 대기 ────────────────────────────────────────────────────────
log "8/8  Waiting for pods to be ready (timeout: 10m)"
kubectl rollout status deploy/monolith -n "$NAMESPACE" --timeout=600s
kubectl rollout status deploy/event-service -n "$NAMESPACE" --timeout=600s

ALB_HOST=$(kubectl get ingress api -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

log "======================================================"
log "  배포 완료!"
log "  ALB endpoint: http://${ALB_HOST}"
log "  부하 테스트 준비 완료"
log "  종료 시: bash scripts/off.sh"
log "======================================================"

slack ":white_check_mark: *point-platform 배포 완료* ($(date +'%H:%M'))\n• ALB: http://${ALB_HOST}\n• 허용 IP: 49.163.124.220, 183.98.203.186, 52.78.206.18\n• 종료: \`bash scripts/off.sh\`"
