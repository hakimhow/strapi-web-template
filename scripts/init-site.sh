#!/usr/bin/env bash
# 交互式初始化一个新站点（SSG + 无公网 IP VPS + Cloudflare Tunnel）

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ask() {
  local var="$1" prompt="$2" default="${3:-}" val=""
  if [[ -n "$default" ]]; then read -rp "$prompt [$default]: " val; val="${val:-$default}"
  else read -rp "$prompt: " val; fi
  eval "$var=\$val"
}
ask_secret() { local var="$1" prompt="$2" val=""; read -rsp "$prompt: " val; echo; eval "$var=\$val"; }
rand() { openssl rand -base64 "${1:-32}" | tr -d '\n=/+' | head -c "${1:-32}"; }

bold "== Astro+Strapi SSG 站点初始化（CF Tunnel 架构）=="

ask SITE_SLUG     "站点 slug（小写、短横线）" "$(basename "$ROOT" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
ask SITE_DOMAIN   "主域名（如 acme.com）"
ask CMS_SUBDOMAIN "Strapi 子域名前缀" "cms"

bold "== Cloudflare Tunnel =="
echo "两种模式选一："
echo "  A) token 模式 —— 在 Cloudflare Dashboard 手动建 tunnel，复制 token 粘贴（最简单）"
echo "  B) CLI 模式  —— 本机已装 cloudflared 且已 login，脚本自动建 tunnel"
ask CF_TUNNEL_MODE "选择模式 [A/B]" "A"

case "${CF_TUNNEL_MODE^^}" in
  A)
    echo "打开：https://one.dash.cloudflare.com/ → Networks → Tunnels → Create a tunnel"
    echo "类型选 Cloudflared，命名为 $SITE_SLUG，创建后复制 token"
    ask_secret CF_TUNNEL_TOKEN "粘贴 Tunnel Token"
    echo "记得在 tunnel 的 Public Hostnames 里加："
    echo "    $SITE_DOMAIN             → http://nginx:80"
    echo "    www.$SITE_DOMAIN         → http://nginx:80"
    echo "    $CMS_SUBDOMAIN.$SITE_DOMAIN → http://nginx:80"
    echo "    cdn.$SITE_DOMAIN         → http://nginx:80"
    ;;
  B)
    command -v cloudflared >/dev/null || { echo "未找到 cloudflared，请先安装或用模式 A"; exit 1; }
    bash infra/cloudflare/setup-tunnel.sh /dev/stdin <<EOF
SITE_SLUG=$SITE_SLUG
SITE_DOMAIN=$SITE_DOMAIN
CMS_SUBDOMAIN=$CMS_SUBDOMAIN
EOF
    echo "从上面输出复制 Tunnel Token："
    ask_secret CF_TUNNEL_TOKEN "粘贴 Tunnel Token"
    ;;
esac

bold "== 远程服务器（生产，通过 VPN 访问）=="
echo "提醒：VPS 无公网 IP，下面填的是 VPN 内网地址"
ask DEPLOY_HOST    "VPS 内网 IP / 主机名"
ask DEPLOY_USER    "SSH 用户" "deploy"
ask DEPLOY_SSH_KEY "本地 SSH 私钥路径" "$HOME/.ssh/id_ed25519"
ask DEPLOY_PATH    "远程部署目录" "/srv/$SITE_SLUG"

bold "== 本地服务器（staging，局域网）=="
ask STAGING_HOST    "本地测试服务器 IP"
ask STAGING_USER    "SSH 用户" "deploy"
ask STAGING_SSH_KEY "本地 SSH 私钥路径" "$HOME/.ssh/id_ed25519"
ask STAGING_PATH    "远程部署目录" "/srv/$SITE_SLUG"

bold "== GHCR =="
ask GHCR_USER "GitHub 用户名/组织"

# 生成密钥
STRAPI_APP_KEYS="$(rand 24),$(rand 24),$(rand 24),$(rand 24)"
STRAPI_API_TOKEN_SALT="$(rand)"
STRAPI_ADMIN_JWT_SECRET="$(rand)"
STRAPI_JWT_SECRET="$(rand)"
STRAPI_TRANSFER_TOKEN_SALT="$(rand)"
DB_PASSWORD="$(rand 24)"
IMAGOR_SECRET="$(rand)"
WEBHOOK_SECRET="$(rand)"

write_env() {
  local file="$1" env="$2" site_url="$3" strapi_url="$4" imagor_url="$5" unsafe="$6" ssh_key="$7" host="$8" path="$9" user="${10}" tunnel_token="${11}"
  cat > "$file" <<EOF
SITE_SLUG=$SITE_SLUG
SITE_DOMAIN=$SITE_DOMAIN
SITE_ENV=$env
NODE_ENV=$([[ $env == local ]] && echo development || echo production)

WEB_PORT=3000
CMS_PORT=1337
IMAGOR_PORT=8000

PUBLIC_SITE_URL=$site_url
PUBLIC_STRAPI_URL=$strapi_url
PUBLIC_IMAGOR_URL=$imagor_url
INTERNAL_STRAPI_URL=http://cms:1337
INTERNAL_IMAGOR_URL=http://imagor:8000

STRAPI_APP_KEYS=$STRAPI_APP_KEYS
STRAPI_API_TOKEN_SALT=$STRAPI_API_TOKEN_SALT
STRAPI_ADMIN_JWT_SECRET=$STRAPI_ADMIN_JWT_SECRET
STRAPI_JWT_SECRET=$STRAPI_JWT_SECRET
STRAPI_TRANSFER_TOKEN_SALT=$STRAPI_TRANSFER_TOKEN_SALT
STRAPI_PUBLIC_TOKEN=

DB_HOST=postgres
DB_PORT=5432
DB_NAME=strapi
DB_USER=strapi
DB_PASSWORD=$DB_PASSWORD
DB_SSL=false

IMAGOR_SECRET=$IMAGOR_SECRET
IMAGOR_UNSAFE=$unsafe

CF_TUNNEL_TOKEN=$tunnel_token
CMS_SUBDOMAIN=$CMS_SUBDOMAIN

DEPLOY_HOST=$host
DEPLOY_USER=$user
DEPLOY_SSH_KEY=$ssh_key
DEPLOY_PATH=$path

GHCR_USER=$GHCR_USER
GHCR_IMAGE_CMS=ghcr.io/$GHCR_USER/$SITE_SLUG-cms
IMAGE_TAG=latest

WEBHOOK_SECRET=$WEBHOOK_SECRET
EOF
  chmod 600 "$file"
  echo "  写入 $file"
}

bold "== 生成环境文件 =="
write_env .env.local      local      "http://localhost:3000" "http://localhost:1337" "http://localhost:8000" "1" "" "" "" "" ""
write_env .env.staging    staging    "https://${SITE_DOMAIN}.local.test" "https://${CMS_SUBDOMAIN}.${SITE_DOMAIN}.local.test" "https://cdn.${SITE_DOMAIN}.local.test" "1" "$STAGING_SSH_KEY" "$STAGING_HOST" "$STAGING_PATH" "$STAGING_USER" ""
write_env .env.production production "https://${SITE_DOMAIN}" "https://${CMS_SUBDOMAIN}.${SITE_DOMAIN}" "https://cdn.${SITE_DOMAIN}" "0" "$DEPLOY_SSH_KEY" "$DEPLOY_HOST" "$DEPLOY_PATH" "$DEPLOY_USER" "$CF_TUNNEL_TOKEN"

bold "== 生成 staging 自签证书 =="
# staging 在内网，仍然需要 HTTPS 模拟生产；CF Tunnel 只管生产
if ! [[ -f infra/nginx/certs/staging.crt ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout infra/nginx/certs/staging.key \
    -out    infra/nginx/certs/staging.crt \
    -subj "/CN=*.${SITE_DOMAIN}.local.test" \
    -addext "subjectAltName=DNS:${SITE_DOMAIN}.local.test,DNS:*.${SITE_DOMAIN}.local.test" 2>/dev/null
  echo "  生成 infra/nginx/certs/staging.{crt,key}"
fi

bold "== 渲染 prod.conf 占位 =="
[[ -f infra/nginx/conf.d/prod.conf.tpl ]] || cp infra/nginx/conf.d/prod.conf infra/nginx/conf.d/prod.conf.tpl
SITE_DOMAIN="$SITE_DOMAIN" CMS_SUBDOMAIN="$CMS_SUBDOMAIN" \
  envsubst '$SITE_DOMAIN $CMS_SUBDOMAIN' \
  < infra/nginx/conf.d/prod.conf.tpl \
  > infra/nginx/conf.d/prod.conf

bold "== git 初始化 =="
if ! [[ -d .git ]]; then
  git init -q
  git add .
  git commit -q -m "chore: init site $SITE_SLUG from template"
fi

bold "== 完成 =="
cat <<EOF

下一步：
  本地开发：
    make dev
    → http://localhost:3000（前端）
    → http://localhost:1337/admin（Strapi，创建管理员）

  首次生产部署（两阶段）：
    1. VPN 连上 VPS 网络
    2. ./scripts/deploy.sh production --cms-first
       → 只起 cms + postgres + imagor + cloudflared
       → 等 cloudflared 建好 tunnel，$PUBLIC_STRAPI_URL/admin 就可达
    3. 在 Strapi admin：
       - 创建管理员账号
       - Settings → API Tokens → 建一个只读 token
       - 发布至少 1 篇示例文章
    4. 把 token 填入 .env.production 的 STRAPI_PUBLIC_TOKEN
    5. ./scripts/deploy.sh production
       → 本地 build 前端 → rsync dist/ → nginx 直出

  Portainer 可以把 $DEPLOY_PATH 下的 compose 作为 Stack 纳管用于日常监控。
EOF
