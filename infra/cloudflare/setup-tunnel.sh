#!/usr/bin/env bash
# 一键为当前站创建 Cloudflare Tunnel + 绑定 public hostname。
# 需要本机已登录 cloudflared：`cloudflared tunnel login`
#
# 替代了旧的 setup-dns.sh（因为 VPS 无公网 IP，不再需要 A 记录）
#
# 用法：
#   ./setup-tunnel.sh <env-file>

set -euo pipefail
ENV_FILE="${1:-$(dirname "$0")/../../.env.production}"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${SITE_SLUG:?}" "${SITE_DOMAIN:?}" "${CMS_SUBDOMAIN:?cms}"

command -v cloudflared >/dev/null || { echo "请先安装 cloudflared"; exit 1; }

TUNNEL_NAME="$SITE_SLUG"

# 1. 创建 tunnel（已存在则复用）
if cloudflared tunnel list --output json | grep -q "\"name\":\"$TUNNEL_NAME\""; then
  echo "Tunnel $TUNNEL_NAME 已存在，复用"
  TUNNEL_UUID=$(cloudflared tunnel list --output json | \
    python3 -c "import json,sys; print([t['id'] for t in json.load(sys.stdin) if t['name']=='$TUNNEL_NAME'][0])")
else
  echo "创建 Tunnel $TUNNEL_NAME"
  cloudflared tunnel create "$TUNNEL_NAME"
  TUNNEL_UUID=$(cloudflared tunnel list --output json | \
    python3 -c "import json,sys; print([t['id'] for t in json.load(sys.stdin) if t['name']=='$TUNNEL_NAME'][0])")
fi

# 2. 拷贝凭证到项目目录
cp "$HOME/.cloudflared/${TUNNEL_UUID}.json" infra/cloudflare/tunnel-credentials.json
chmod 600 infra/cloudflare/tunnel-credentials.json

# 3. 渲染 tunnel-config.yml
SITE_DOMAIN="$SITE_DOMAIN" CMS_SUBDOMAIN="$CMS_SUBDOMAIN" TUNNEL_UUID="$TUNNEL_UUID" \
  envsubst '$SITE_DOMAIN $CMS_SUBDOMAIN $TUNNEL_UUID' \
  < infra/cloudflare/tunnel-config.yml.example \
  > infra/cloudflare/tunnel-config.yml
# envsubst 不会替换 $TUNNEL_UUID 里的尖括号占位，手动替换一次
sed -i "s/<TUNNEL_UUID>/$TUNNEL_UUID/" infra/cloudflare/tunnel-config.yml

# 4. 绑定 DNS（CNAME → tunnel.cfargotunnel.com）
for host in "$SITE_DOMAIN" "www.$SITE_DOMAIN" "$CMS_SUBDOMAIN.$SITE_DOMAIN" "cdn.$SITE_DOMAIN"; do
  echo "绑定 $host → $TUNNEL_UUID"
  cloudflared tunnel route dns --overwrite-dns "$TUNNEL_UUID" "$host" || true
done

# 5. 打印 token（给 compose.prod.yml 的模式 A 用）
echo
echo "== Tunnel UUID: $TUNNEL_UUID =="
echo "== 获取 token（用于 compose.prod.yml 模式 A）=="
cloudflared tunnel token "$TUNNEL_UUID" && echo
echo
echo "请把上面的 token 填入 $ENV_FILE 的 CF_TUNNEL_TOKEN"
