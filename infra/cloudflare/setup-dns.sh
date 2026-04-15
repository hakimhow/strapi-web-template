#!/usr/bin/env bash
# 在 Cloudflare 上为当前站点创建/更新 A 记录。
# 参数通过 .env 文件注入：CF_API_TOKEN, CF_ZONE_ID, SITE_DOMAIN, DEPLOY_HOST, CF_PROXIED
#
# 用法：
#   ./setup-dns.sh <env-file>
#   默认 env-file = ../../.env.production

set -euo pipefail

ENV_FILE="${1:-$(dirname "$0")/../../.env.production}"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${CF_API_TOKEN:?CF_API_TOKEN 未设置}"
: "${CF_ZONE_ID:?CF_ZONE_ID 未设置}"
: "${SITE_DOMAIN:?SITE_DOMAIN 未设置}"
: "${DEPLOY_HOST:?DEPLOY_HOST 未设置 —— 需要服务器 IP}"
PROXIED="${CF_PROXIED:-false}"

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

upsert_a() {
  local name="$1" content="$2" proxied="$3"
  # 查找现有记录
  local existing_id
  existing_id=$(curl -sS "${AUTH[@]}" "${API}/zones/${CF_ZONE_ID}/dns_records?type=A&name=${name}" \
    | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4 || true)

  local payload
  payload=$(printf '{"type":"A","name":"%s","content":"%s","proxied":%s,"ttl":1}' "$name" "$content" "$proxied")

  if [[ -n "${existing_id}" ]]; then
    echo "更新 $name → $content (proxied=$proxied)"
    curl -sS -X PUT "${AUTH[@]}" "${API}/zones/${CF_ZONE_ID}/dns_records/${existing_id}" --data "$payload" >/dev/null
  else
    echo "创建 $name → $content (proxied=$proxied)"
    curl -sS -X POST "${AUTH[@]}" "${API}/zones/${CF_ZONE_ID}/dns_records" --data "$payload" >/dev/null
  fi
}

upsert_a "${SITE_DOMAIN}"          "${DEPLOY_HOST}" "${PROXIED}"
upsert_a "www.${SITE_DOMAIN}"      "${DEPLOY_HOST}" "${PROXIED}"
upsert_a "cms.${SITE_DOMAIN}"      "${DEPLOY_HOST}" "${PROXIED}"
upsert_a "cdn.${SITE_DOMAIN}"      "${DEPLOY_HOST}" "${PROXIED}"

echo "DNS 配置完成（proxied=${PROXIED}）"
