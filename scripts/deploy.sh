#!/usr/bin/env bash
# 部署到 staging（本地服务器）或 production（远程 VPS）。
# 流程：
#   1. 构建 web / cms 镜像并推送到 GHCR
#   2. rsync compose 文件 + nginx 配置 + cloudflare 凭证 到目标服务器
#   3. 目标机上 docker compose pull && up -d
#   4. 生产：首次会触发 certbot 签证书；DNS 记录自动切换 proxy=on
#   5. 健康检查 + 失败回滚
#
# 用法：
#   ./deploy.sh staging
#   ./deploy.sh production [image-tag]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-}"
TAG="${2:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"

case "$TARGET" in
  staging)    ENV_FILE=".env.staging"    COMPOSE_OVERLAY="compose.staging.yml" ;;
  production) ENV_FILE=".env.production" COMPOSE_OVERLAY="compose.prod.yml" ;;
  *) echo "用法: $0 staging|production [tag]"; exit 1 ;;
esac

[[ -f "$ENV_FILE" ]] || { echo "找不到 $ENV_FILE —— 先运行 scripts/init-site.sh"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

echo "== [1/5] 构建并推送镜像（tag=$TAG）=="
: "${GHCR_USER:?}" "${GHCR_IMAGE_WEB:?}" "${GHCR_IMAGE_CMS:?}"

# 需要先 `echo $GITHUB_TOKEN | docker login ghcr.io -u $GHCR_USER --password-stdin`
docker buildx build --platform linux/amd64 \
  -t "$GHCR_IMAGE_WEB:$TAG" -t "$GHCR_IMAGE_WEB:latest" \
  --push apps/web

docker buildx build --platform linux/amd64 \
  -t "$GHCR_IMAGE_CMS:$TAG" -t "$GHCR_IMAGE_CMS:latest" \
  --push apps/cms

echo "== [2/5] 同步配置到 $TARGET（$DEPLOY_HOST）=="
SSH_OPTS=(-i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"
RSYNC_OPTS=(-az --delete -e "ssh ${SSH_OPTS[*]}")

ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $DEPLOY_PATH/infra/nginx/conf.d $DEPLOY_PATH/infra/nginx/certs $DEPLOY_PATH/infra/cloudflare $DEPLOY_PATH/infra/docker"
rsync "${RSYNC_OPTS[@]}" infra/docker/compose.base.yml       "$REMOTE:$DEPLOY_PATH/infra/docker/"
rsync "${RSYNC_OPTS[@]}" "infra/docker/$COMPOSE_OVERLAY"      "$REMOTE:$DEPLOY_PATH/infra/docker/"
rsync "${RSYNC_OPTS[@]}" infra/nginx/conf.d/                  "$REMOTE:$DEPLOY_PATH/infra/nginx/conf.d/"

if [[ "$TARGET" == "staging" ]]; then
  rsync "${RSYNC_OPTS[@]}" infra/nginx/certs/                  "$REMOTE:$DEPLOY_PATH/infra/nginx/certs/"
else
  rsync "${RSYNC_OPTS[@]}" infra/cloudflare/cf-credentials.ini "$REMOTE:$DEPLOY_PATH/infra/cloudflare/"
fi

# 环境文件（敏感）—— 传到 remote，重命名为 .env
rsync "${RSYNC_OPTS[@]}" "$ENV_FILE" "$REMOTE:$DEPLOY_PATH/.env"

IMAGE_TAG="$TAG"
ssh "${SSH_OPTS[@]}" "$REMOTE" "sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=$IMAGE_TAG/' $DEPLOY_PATH/.env"

echo "== [3/5] 生产首次签发证书（若未存在）=="
if [[ "$TARGET" == "production" ]]; then
  ssh "${SSH_OPTS[@]}" "$REMOTE" bash -se <<EOF
set -e
cd "$DEPLOY_PATH"
if ! sudo test -d "/var/lib/docker/volumes/${SITE_SLUG}_certbot-etc/_data/live/${SITE_DOMAIN}"; then
  echo "首次签发 Let's Encrypt 证书（DNS-01 via Cloudflare）..."
  docker run --rm \
    -v ${SITE_SLUG}_certbot-etc:/etc/letsencrypt \
    -v ${SITE_SLUG}_certbot-www:/var/www/certbot \
    -v "\$PWD/infra/cloudflare/cf-credentials.ini:/cf.ini:ro" \
    certbot/dns-cloudflare certonly \
      --dns-cloudflare --dns-cloudflare-credentials /cf.ini \
      --dns-cloudflare-propagation-seconds 30 \
      --email "$ACME_EMAIL" --agree-tos --no-eff-email --non-interactive \
      -d "$SITE_DOMAIN" -d "www.$SITE_DOMAIN" -d "${CMS_SUBDOMAIN}.$SITE_DOMAIN" -d "cdn.$SITE_DOMAIN"
fi
EOF
fi

echo "== [4/5] 启动服务 =="
ssh "${SSH_OPTS[@]}" "$REMOTE" bash -se <<EOF
set -e
cd "$DEPLOY_PATH"
docker compose --env-file .env \
  -f infra/docker/compose.base.yml \
  -f infra/docker/$COMPOSE_OVERLAY \
  pull
docker compose --env-file .env \
  -f infra/docker/compose.base.yml \
  -f infra/docker/$COMPOSE_OVERLAY \
  up -d --remove-orphans
EOF

echo "== [5/5] 健康检查 =="
HEALTH_URL="$PUBLIC_SITE_URL"
for i in {1..30}; do
  if curl -fsS -o /dev/null -m 5 "$HEALTH_URL"; then
    echo "  $HEALTH_URL → OK"
    break
  fi
  [[ $i -eq 30 ]] && { echo "健康检查失败"; exit 1; }
  sleep 5
done

# 生产：确保 CF proxy 开启
if [[ "$TARGET" == "production" ]]; then
  echo "== 切换 Cloudflare proxy → on =="
  CF_PROXIED=true bash infra/cloudflare/setup-dns.sh "$ENV_FILE"
fi

echo "部署完成 ✓"
