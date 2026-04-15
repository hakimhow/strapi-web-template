#!/usr/bin/env bash
# SSG 部署：
#   1. 构建并推送 cms 镜像到 GHCR
#   2. 本地构建 web 静态产物 dist/（fetch 远程 Strapi 数据）
#   3. rsync dist/ + compose + nginx + env 到目标机
#   4. 目标机 docker compose up -d；web 由 nginx 服务 dist/
#   5. 生产：首次签发证书、健康检查、切 CF proxy=on
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

echo "== [1/6] 构建并推送 CMS 镜像（tag=$TAG）=="
: "${GHCR_USER:?}" "${GHCR_IMAGE_CMS:?}"
docker buildx build --platform linux/amd64 \
  -t "$GHCR_IMAGE_CMS:$TAG" -t "$GHCR_IMAGE_CMS:latest" \
  --push apps/cms

echo "== [2/6] 本地构建前端静态产物 =="
# 为了在 build 时拉到数据，需要 Strapi 对构建机可达。两种模式：
#   a) Strapi 已在目标机部署且公开（常见）→ 直接 fetch $PUBLIC_STRAPI_URL
#   b) 首次部署 CMS 尚未就绪 → 先部署 cms，再 build 前端
#
# 这里默认 a)：首次请先跑 ./deploy.sh <target> --cms-only（见下文 TODO）
pushd apps/web >/dev/null
npm ci --silent
PUBLIC_SITE_URL="$PUBLIC_SITE_URL" \
PUBLIC_STRAPI_URL="$PUBLIC_STRAPI_URL" \
PUBLIC_IMAGOR_URL="$PUBLIC_IMAGOR_URL" \
INTERNAL_STRAPI_URL="$PUBLIC_STRAPI_URL" \
STRAPI_PUBLIC_TOKEN="$STRAPI_PUBLIC_TOKEN" \
  npm run build
popd >/dev/null
[[ -d apps/web/dist ]] || { echo "构建失败：apps/web/dist 不存在"; exit 1; }

echo "== [3/6] 同步到 $TARGET（$DEPLOY_HOST）=="
SSH_OPTS=(-i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"
RSYNC_OPTS=(-az --delete -e "ssh ${SSH_OPTS[*]}")

ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $DEPLOY_PATH/infra/nginx/conf.d $DEPLOY_PATH/infra/nginx/certs $DEPLOY_PATH/infra/cloudflare $DEPLOY_PATH/infra/docker $DEPLOY_PATH/dist.new"
rsync "${RSYNC_OPTS[@]}" apps/web/dist/                       "$REMOTE:$DEPLOY_PATH/dist.new/"
rsync "${RSYNC_OPTS[@]}" infra/docker/compose.base.yml        "$REMOTE:$DEPLOY_PATH/infra/docker/"
rsync "${RSYNC_OPTS[@]}" "infra/docker/$COMPOSE_OVERLAY"       "$REMOTE:$DEPLOY_PATH/infra/docker/"
rsync "${RSYNC_OPTS[@]}" infra/nginx/conf.d/                   "$REMOTE:$DEPLOY_PATH/infra/nginx/conf.d/"

if [[ "$TARGET" == "staging" ]]; then
  rsync "${RSYNC_OPTS[@]}" infra/nginx/certs/                   "$REMOTE:$DEPLOY_PATH/infra/nginx/certs/"
else
  rsync "${RSYNC_OPTS[@]}" infra/cloudflare/cf-credentials.ini  "$REMOTE:$DEPLOY_PATH/infra/cloudflare/"
fi

rsync "${RSYNC_OPTS[@]}" "$ENV_FILE" "$REMOTE:$DEPLOY_PATH/.env"
ssh "${SSH_OPTS[@]}" "$REMOTE" "sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=$TAG/' $DEPLOY_PATH/.env"

echo "== [4/6] 原子切换 dist/ =="
ssh "${SSH_OPTS[@]}" "$REMOTE" bash -se <<EOF
set -e
cd "$DEPLOY_PATH"
if [[ -d dist ]]; then mv dist dist.old.$(date +%s); fi
mv dist.new dist
# 保留最近两份 rollback 用
ls -dt dist.old.* 2>/dev/null | tail -n +3 | xargs -r rm -rf
# nginx 容器挂的是 bind mount，文件级替换它会直接看到新内容，无需 reload
EOF

echo "== [5/6] 启动 / 更新服务 =="
if [[ "$TARGET" == "production" ]]; then
  ssh "${SSH_OPTS[@]}" "$REMOTE" bash -se <<EOF
set -e
cd "$DEPLOY_PATH"
if ! sudo test -d "/var/lib/docker/volumes/${SITE_SLUG}_certbot-etc/_data/live/${SITE_DOMAIN}"; then
  echo "首次签发 Let's Encrypt 证书..."
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

echo "== [6/6] 健康检查 =="
for i in {1..30}; do
  if curl -fsS -o /dev/null -m 5 "$PUBLIC_SITE_URL"; then
    echo "  $PUBLIC_SITE_URL → OK"
    break
  fi
  [[ $i -eq 30 ]] && { echo "健康检查失败"; exit 1; }
  sleep 5
done

if [[ "$TARGET" == "production" ]]; then
  echo "== 切换 Cloudflare proxy → on =="
  CF_PROXIED=true bash infra/cloudflare/setup-dns.sh "$ENV_FILE"
fi

echo "部署完成 ✓"
