#!/usr/bin/env bash
# SSG 部署 —— 适配「无公网 IP VPS + VPN + Docker + Portainer + Cloudflare Tunnel」
#
# 流程：
#   1. 检查与 VPS 的 SSH 连通（VPN 必须已连上）
#   2. 构建并推送 cms 镜像到 GHCR
#   3. 本地构建 web 静态产物 dist/（需要能访问 Strapi —— 所以首次部署要分两阶段）
#   4. rsync dist + compose + nginx + cloudflared 配置到 VPS
#   5. VPS 上 docker compose up
#   6. 健康检查（通过 Cloudflare 公共域名，而非 VPS IP）
#
# 用法：
#   ./deploy.sh <target> [options]
#   target : staging | production
#   --cms-first   : 只部署数据库 + CMS + Tunnel，不构建前端。首次部署新站必用。
#   --tag <tag>   : 指定镜像 tag（默认 git sha）
#
# 典型首次部署流程：
#   ./deploy.sh production --cms-first   # 起 cms，在 admin 建内容、生成 API token
#   # 把 token 填进 .env.production 的 STRAPI_PUBLIC_TOKEN
#   ./deploy.sh production               # 完整部署（含前端构建）

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="" TAG="" CMS_FIRST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    staging|production) TARGET="$1"; shift ;;
    --cms-first) CMS_FIRST=1; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "用法: $0 staging|production [--cms-first] [--tag <tag>]"; exit 1; }
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"

case "$TARGET" in
  staging)    ENV_FILE=".env.staging"    COMPOSE_OVERLAY="compose.staging.yml" ;;
  production) ENV_FILE=".env.production" COMPOSE_OVERLAY="compose.prod.yml" ;;
esac

[[ -f "$ENV_FILE" ]] || { echo "找不到 $ENV_FILE —— 先运行 scripts/init-site.sh"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

SSH_OPTS=(-i "$DEPLOY_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"
RSYNC_OPTS=(-az --delete -e "ssh ${SSH_OPTS[*]}")

# ---- 0. VPN/SSH 连通检查 ----
echo "== [0] 检查 VPN → $DEPLOY_HOST =="
if ! ssh "${SSH_OPTS[@]}" "$REMOTE" true 2>/dev/null; then
  cat >&2 <<EOF
无法 SSH 到 $DEPLOY_HOST
  - 生产 VPS 无公网 IP，请确认 VPN 已连接
  - SSH key: $DEPLOY_SSH_KEY
  - 用户@主机: $REMOTE
EOF
  exit 1
fi
echo "  OK"

# ---- 1. 构建推送 CMS 镜像 ----
echo "== [1] 构建并推送 CMS 镜像（tag=$TAG）=="
: "${GHCR_IMAGE_CMS:?}"
docker buildx build --platform linux/amd64 \
  -t "$GHCR_IMAGE_CMS:$TAG" -t "$GHCR_IMAGE_CMS:latest" \
  --push apps/cms

# ---- 2. 同步配置 ----
echo "== [2] 同步基础配置到 VPS =="
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p \
  $DEPLOY_PATH/infra/docker \
  $DEPLOY_PATH/infra/nginx/conf.d \
  $DEPLOY_PATH/infra/cloudflare"

rsync "${RSYNC_OPTS[@]}" infra/docker/compose.base.yml         "$REMOTE:$DEPLOY_PATH/infra/docker/"
rsync "${RSYNC_OPTS[@]}" "infra/docker/$COMPOSE_OVERLAY"        "$REMOTE:$DEPLOY_PATH/infra/docker/"
rsync "${RSYNC_OPTS[@]}" infra/nginx/conf.d/                    "$REMOTE:$DEPLOY_PATH/infra/nginx/conf.d/"

# Tunnel 凭证
if [[ -f infra/cloudflare/tunnel-credentials.json ]]; then
  rsync "${RSYNC_OPTS[@]}" infra/cloudflare/tunnel-credentials.json "$REMOTE:$DEPLOY_PATH/infra/cloudflare/"
fi
if [[ -f infra/cloudflare/tunnel-config.yml ]]; then
  rsync "${RSYNC_OPTS[@]}" infra/cloudflare/tunnel-config.yml "$REMOTE:$DEPLOY_PATH/infra/cloudflare/"
fi

rsync "${RSYNC_OPTS[@]}" "$ENV_FILE" "$REMOTE:$DEPLOY_PATH/.env"
ssh "${SSH_OPTS[@]}" "$REMOTE" "sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=$TAG/' $DEPLOY_PATH/.env"

# ---- 3. --cms-first：只起后端，跳过前端 ----
if [[ "$CMS_FIRST" -eq 1 ]]; then
  echo "== [3a] 仅启动 postgres + cms + imagor + cloudflared（--cms-first 模式）=="
  # dist 目录占位（nginx volume 需要），随便放个 placeholder
  ssh "${SSH_OPTS[@]}" "$REMOTE" bash -se <<EOF
set -e
cd "$DEPLOY_PATH"
if [[ ! -d dist ]]; then
  mkdir -p dist
  echo '<h1>Site being initialized...</h1>' > dist/index.html
fi
docker compose --env-file .env \
  -f infra/docker/compose.base.yml \
  -f infra/docker/$COMPOSE_OVERLAY \
  up -d postgres cms imagor cloudflared
EOF

  echo "== [3b] 等待 Strapi 就绪 =="
  for i in {1..60}; do
    if curl -fsS -o /dev/null -m 5 "$PUBLIC_STRAPI_URL/_health" 2>/dev/null \
       || curl -fsS -o /dev/null -m 5 "$PUBLIC_STRAPI_URL/admin" 2>/dev/null; then
      echo "  Strapi 已就绪：$PUBLIC_STRAPI_URL/admin"
      break
    fi
    [[ $i -eq 60 ]] && { echo "Strapi 启动超时（5 分钟），请检查日志"; exit 1; }
    sleep 5
  done

  cat <<EOF

✅ CMS-first 阶段完成

下一步：
  1. 打开 $PUBLIC_STRAPI_URL/admin 创建管理员账号
  2. Settings → API Tokens → 新建只读 token（Duration: Unlimited, Type: Read-only）
  3. 把 token 填入 $ENV_FILE 的 STRAPI_PUBLIC_TOKEN
  4. 在 Content Manager 里至少发布 1 篇文章（否则 build 时 /articles 会 404）
  5. 执行完整部署：
       ./scripts/deploy.sh $TARGET
EOF
  exit 0
fi

# ---- 3. 常规部署：检查 STRAPI_PUBLIC_TOKEN ----
if [[ -z "${STRAPI_PUBLIC_TOKEN:-}" ]]; then
  cat >&2 <<EOF
❌ STRAPI_PUBLIC_TOKEN 为空

SSG 模式在构建时需要这个 token 拉取 Strapi 数据。
如果这是新站首次部署，请先运行：
  ./scripts/deploy.sh $TARGET --cms-first
EOF
  exit 1
fi

# ---- 4. 本地构建前端 ----
echo "== [4] 本地构建前端静态产物 =="
pushd apps/web >/dev/null
npm ci --silent
# 因为 VPS 没公网 IP，本地 build 必须通过 Cloudflare Tunnel 访问 Strapi（走公网域名）
PUBLIC_SITE_URL="$PUBLIC_SITE_URL" \
PUBLIC_STRAPI_URL="$PUBLIC_STRAPI_URL" \
PUBLIC_IMAGOR_URL="$PUBLIC_IMAGOR_URL" \
INTERNAL_STRAPI_URL="$PUBLIC_STRAPI_URL" \
STRAPI_PUBLIC_TOKEN="$STRAPI_PUBLIC_TOKEN" \
  npm run build
popd >/dev/null
[[ -d apps/web/dist ]] || { echo "构建失败：apps/web/dist 不存在"; exit 1; }

# ---- 5. 推送 dist 到 VPS 并原子切换 ----
echo "== [5] 同步 dist/ 到 VPS 并原子替换 =="
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $DEPLOY_PATH/dist.new"
rsync "${RSYNC_OPTS[@]}" apps/web/dist/ "$REMOTE:$DEPLOY_PATH/dist.new/"

ssh "${SSH_OPTS[@]}" "$REMOTE" bash -se <<EOF
set -e
cd "$DEPLOY_PATH"
if [[ -d dist ]]; then mv dist dist.old.\$(date +%s); fi
mv dist.new dist
ls -dt dist.old.* 2>/dev/null | tail -n +3 | xargs -r rm -rf
EOF

# ---- 6. 启动/更新所有服务 ----
echo "== [6] docker compose up -d =="
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

# ---- 7. 健康检查（走 CF Tunnel 的公共域名）----
echo "== [7] 健康检查：$PUBLIC_SITE_URL =="
for i in {1..30}; do
  if curl -fsS -o /dev/null -m 10 "$PUBLIC_SITE_URL"; then
    echo "  OK"
    break
  fi
  [[ $i -eq 30 ]] && { echo "健康检查失败 —— 检查 cloudflared 日志与 tunnel hostname 配置"; exit 1; }
  sleep 5
done

echo "✅ 部署完成"
