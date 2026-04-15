#!/usr/bin/env bash
# 从远程拉数据库到本地（或反向推送），用于用生产数据在本地复现问题
# 用法：
#   ./sync-db.sh pull production   # 远程 → 本地
#   ./sync-db.sh pull staging
#   ./sync-db.sh push staging      # 本地 → staging（危险！会覆盖）

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIR="${1:-}"; TARGET="${2:-}"
case "$TARGET" in
  staging)    ENV_FILE=".env.staging" ;;
  production) ENV_FILE=".env.production" ;;
  *) echo "用法: $0 pull|push staging|production"; exit 1 ;;
esac
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
SSH="ssh -i $DEPLOY_SSH_KEY $DEPLOY_USER@$DEPLOY_HOST"

TS="$(date +%Y%m%d-%H%M%S)"
DUMP="backups/${TARGET}-${TS}.sql.gz"
mkdir -p backups

case "$DIR" in
  pull)
    echo "从 $TARGET 导出数据库..."
    $SSH "cd $DEPLOY_PATH && docker compose exec -T postgres pg_dump -U $DB_USER $DB_NAME" | gzip > "$DUMP"
    echo "保存到 $DUMP"
    read -rp "立即导入本地？[y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      gunzip -c "$DUMP" | docker compose --env-file .env.local \
        -f infra/docker/compose.base.yml -f infra/docker/compose.dev.yml \
        exec -T postgres psql -U "$DB_USER" -d "$DB_NAME"
    fi
    ;;
  push)
    [[ -f "$DUMP" ]] || { echo "请先 pull"; exit 1; }
    echo "警告：将覆盖 $TARGET 数据库！"
    read -rp "输入 $TARGET 确认: " yn
    [[ "$yn" == "$TARGET" ]] || { echo "取消"; exit 1; }
    gunzip -c "$DUMP" | $SSH "cd $DEPLOY_PATH && docker compose exec -T postgres psql -U $DB_USER -d $DB_NAME"
    ;;
  *) echo "用法: $0 pull|push staging|production"; exit 1 ;;
esac
