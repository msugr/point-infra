#!/usr/bin/env bash
# 테스트 완료 후 리소스 중지 (terminate X, stop/scale-down O)
set -euo pipefail

REGION="ap-northeast-2"
CLUSTER_NAME="point-main-eks"
TF_MAIN="infra/terraform/envs/aws-main"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "리소스 종료 시작 (데이터 보존, terminate 없음)"

# ── 1. EKS 노드 그룹 scale-to-0 ──────────────────────────────────────────────
log "1/3  EKS 노드 그룹 scale-down → 0"
NODE_GROUPS=$(aws eks list-nodegroups \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'nodegroups[]' --output text)

for NG in $NODE_GROUPS; do
  log "     Scaling $NG to 0"
  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NG" \
    --region "$REGION" \
    --scaling-config minSize=0,maxSize=4,desiredSize=0
done

# ── 2. Aurora 클러스터 stop ───────────────────────────────────────────────────
log "2/3  Aurora 클러스터 stop"
cd "$TF_MAIN"
AURORA_CLUSTER_ID=$(terraform output -raw aurora_endpoint | cut -d. -f1)
cd - > /dev/null

aws rds stop-db-cluster \
  --db-cluster-identifier "${AURORA_CLUSTER_ID}" \
  --region "$REGION" || log "     Aurora already stopped or not found"

# ── 3. 완료 메시지 ────────────────────────────────────────────────────────────
log "3/3  완료"
log "======================================================"
log "  EKS 노드: scale-down 완료 (노드그룹 설정 보존)"
log "  Aurora: 중지 완료 (데이터 보존, 재시작 가능)"
log "  EKS 컨트롤 플레인: 그대로 유지 (AWS 관리형)"
log ""
log "  재시작: EKS 노드그룹 desired 복원 + Aurora start-db-cluster"
log "======================================================"
