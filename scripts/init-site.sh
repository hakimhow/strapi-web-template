#!/usr/bin/env bash
# 交互式初始化一个新站点：
# - 询问域名、CF token、SSH key、远程服务器等
# - 生成 .env.local / .env.staging / .env.production
# - 生成 infra/cloudflare/cf-credentials.ini（certbot 用）
# - 生成 infra/nginx/certs/staging.{crt,key}（自签）
# - 根据 SITE_DOMAIN 渲染 infra/nginx/conf.d/prod.conf 里的 ${...} 占位
# - 首次 git init + commit

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ask() {
  local var="$1" prompt="$2" default="${3:-}" val=""
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " val
    val="${val:-$default}"
  else
    read -rp "$prompt: " val
  fi
  eval "$var=\$val"
}
ask_secret() {
  local var="$1" prompt="$2" val=""
  read -rsp "$prompt: " val; echo
  eval "$var=\$val"
}
rand() { openssl rand -base64 "${1:-32}" | tr -d '\n=/+' | head -c "${1:-32}"; }

bold "== Astro+Strapi 站点初始化 =="

ask SITE_SLUG       "站点 slug（小写、短横线）" "$(basename "$ROOT" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
ask SITE_DOMAIN     "主域名（如 acme.com）"
ask CMS_SUBDOMAIN   "Strapi 子域名前缀" "cms"
ask ACME_EMAIL      "Let's Encrypt 联系邮箱"

bold "== Cloudflare =="
ask_secret CF_API_TOKEN "Cloudflare API Token（Zone:DNS:Edit）"
ask        CF_ZONE_ID   "Cloudflare Zone ID"

bold "== 远程服务器（生产）=="
ask DEPLOY_HOST    "远程服务器 IP 或域名"
ask DEPLOY_USER    "SSH 用户" "deploy"
ask DEPLOY_SSH_KEY "本地 SSH 私钥路径" "$HOME/.ssh/id_ed25519"
ask DEPLOY_PATH    "远程部署目录" "/srv/$SITE_SLUG"

bold "== 本地服务器（staging）=="
ask STAGING_HOST    "本地服务器 IP（局域网内）"
ask STAGING_USER    "SSH 用户" "deploy"
ask STAGING_SSH_KEY "本地 SSH 私钥路径" "$HOME/.ssh/id_ed25519"
ask STAGING_PATH    "远程部署目录" "/srv/$SITE_SLUG"

bold "== GHCR =="
ask GHCR_USER "GitHub 用户名/组织"

# 自动生成密钥
STRAPI_APP_KEYS="$(rand 24),$(rand 24),$(rand 24),$(rand 24)"
STRAPI_API_TOKEN_SALT="$(rand)"
STRAPI_ADMIN_JWT_SECRET="$(rand)"
STRAPI_JWT_SECRET="$(rand)"
STRAPI_TRANSFER_TOKEN_SALT="$(rand)"
DB_PASSWORD="$(rand 24)"
IMAGOR_SECRET="$(rand)"

write_env() {
  local file="$1" env="$2" site_url="$3" strapi_url="$4" imagor_url="$5" proxied="$6" unsafe="$7" ssh_key="$8" host="$9" path="${10}" user="${11}"
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

CF_API_TOKEN=$CF_API_TOKEN
CF_ZONE_ID=$CF_ZONE_ID
CF_PROXIED=$proxied

DEPLOY_HOST=$host
DEPLOY_USER=$user
DEPLOY_SSH_KEY=$ssh_key
DEPLOY_PATH=$path

GHCR_USER=$GHCR_USER
GHCR_IMAGE_WEB=ghcr.io/$GHCR_USER/$SITE_SLUG-web
GHCR_IMAGE_CMS=ghcr.io/$GHCR_USER/$SITE_SLUG-cms
IMAGE_TAG=latest

ACME_EMAIL=$ACME_EMAIL
CMS_SUBDOMAIN=$CMS_SUBDOMAIN
EOF
  chmod 600 "$file"
  echo "  写入 $file"
}

bold "== 生成环境文件 =="
write_env .env.local      local      "http://localhost:3000" "http://localhost:1337" "http://localhost:8000" "false" "1" "" "" "" ""
write_env .env.staging    staging    "https://${SITE_DOMAIN}.local.test" "https://${CMS_SUBDOMAIN}.${SITE_DOMAIN}.local.test" "https://cdn.${SITE_DOMAIN}.local.test" "false" "1" "$STAGING_SSH_KEY" "$STAGING_HOST" "$STAGING_PATH" "$STAGING_USER"
write_env .env.production production "https://${SITE_DOMAIN}" "https://${CMS_SUBDOMAIN}.${SITE_DOMAIN}" "https://cdn.${SITE_DOMAIN}" "true" "0" "$DEPLOY_SSH_KEY" "$DEPLOY_HOST" "$DEPLOY_PATH" "$DEPLOY_USER"

bold "== Cloudflare 凭证（certbot）=="
cat > infra/cloudflare/cf-credentials.ini <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
chmod 600 infra/cloudflare/cf-credentials.ini
echo "  写入 infra/cloudflare/cf-credentials.ini"

bold "== 生成 staging 自签证书 =="
if ! [[ -f infra/nginx/certs/staging.crt ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout infra/nginx/certs/staging.key \
    -out    infra/nginx/certs/staging.crt \
    -subj "/CN=*.${SITE_DOMAIN}.local.test" \
    -addext "subjectAltName=DNS:${SITE_DOMAIN}.local.test,DNS:*.${SITE_DOMAIN}.local.test" 2>/dev/null
  echo "  生成 infra/nginx/certs/staging.{crt,key}"
else
  echo "  已存在，跳过"
fi

bold "== 渲染 prod.conf 占位 =="
# 备份原模板一次
[[ -f infra/nginx/conf.d/prod.conf.tpl ]] || cp infra/nginx/conf.d/prod.conf infra/nginx/conf.d/prod.conf.tpl
SITE_DOMAIN="$SITE_DOMAIN" CMS_SUBDOMAIN="$CMS_SUBDOMAIN" \
  envsubst '$SITE_DOMAIN $CMS_SUBDOMAIN' \
  < infra/nginx/conf.d/prod.conf.tpl \
  > infra/nginx/conf.d/prod.conf
echo "  渲染完成"

bold "== 创建 Cloudflare DNS 记录（仅 DNS，proxy 关闭）=="
read -rp "现在就调 CF API 创建 DNS 记录吗？[y/N]: " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  CF_PROXIED=false bash infra/cloudflare/setup-dns.sh .env.production
fi

bold "== git 初始化 =="
if ! [[ -d .git ]]; then
  git init -q
  git add .
  git commit -q -m "chore: init site $SITE_SLUG from template"
  echo "  git 仓库已初始化"
else
  echo "  已是 git 仓库，跳过"
fi

bold "== 完成 =="
cat <<EOF

下一步：
  make dev                       # 本地开发
  访问 http://localhost:3000     # 前端
  访问 http://localhost:1337/admin  # 创建 Strapi 管理员

发布前：
  1. 在 Strapi admin 生成一个只读 API token，填入 .env.production 的 STRAPI_PUBLIC_TOKEN
  2. make push                                 # 构建并推送镜像到 GHCR
  3. ./scripts/deploy.sh staging               # 先发本地服务器确认
  4. ./scripts/deploy.sh production            # 最后发生产 VPS
     （部署脚本会自动切换 CF proxy → on）
EOF
