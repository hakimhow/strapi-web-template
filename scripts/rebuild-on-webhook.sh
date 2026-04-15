#!/usr/bin/env bash
# 在远程服务器上以 systemd 服务方式运行的 webhook 接收器。
# Strapi 发布文章后 POST 到本服务，触发 rebuild → 原子替换 dist/。
#
# 安装（在远程服务器上一次性执行）：
#   sudo cp scripts/rebuild-on-webhook.sh /usr/local/bin/
#   sudo cp scripts/rebuild-on-webhook.service /etc/systemd/system/
#   sudo systemctl enable --now rebuild-on-webhook
#
# Strapi 里配 webhook URL: https://<site>/hooks/rebuild
# nginx 把 /hooks/rebuild 代理到 127.0.0.1:9999

set -euo pipefail
PORT="${WEBHOOK_PORT:-9999}"
SITE_PATH="${SITE_PATH:-/srv/example-site}"
SECRET="${WEBHOOK_SECRET:-}"

log() { echo "[$(date -Iseconds)] $*"; }

rebuild() {
  log "开始 rebuild"
  cd "$SITE_PATH"
  # .env 已同步到服务器；读取出来供 build 用
  set -a; source .env; set +a

  # 在容器里构建（避免污染宿主机 node 环境）
  docker run --rm \
    -v "$SITE_PATH/apps/web:/opt/app" \
    -w /opt/app \
    -e PUBLIC_SITE_URL="$PUBLIC_SITE_URL" \
    -e PUBLIC_STRAPI_URL="$PUBLIC_STRAPI_URL" \
    -e PUBLIC_IMAGOR_URL="$PUBLIC_IMAGOR_URL" \
    -e INTERNAL_STRAPI_URL="http://${SITE_SLUG}-cms:1337" \
    -e STRAPI_PUBLIC_TOKEN="$STRAPI_PUBLIC_TOKEN" \
    --network "${SITE_SLUG}-net" \
    node:20-alpine \
    sh -c "npm ci --silent && npm run build"

  # 原子替换
  if [[ -d dist ]]; then mv dist "dist.old.$(date +%s)"; fi
  mv apps/web/dist dist
  ls -dt dist.old.* 2>/dev/null | tail -n +3 | xargs -r rm -rf
  log "rebuild 完成"
}

# 简易 HTTP 接收器（仅内网，经 nginx 代理进来）
while true; do
  log "监听 127.0.0.1:$PORT"
  # 用 ncat 接一个请求
  REQ="$(ncat -l -p "$PORT" -q 1 -w 30 2>/dev/null || true)"
  [[ -z "$REQ" ]] && continue

  if [[ -n "$SECRET" ]] && ! grep -q "X-Strapi-Signature: $SECRET" <<<"$REQ"; then
    log "签名无效，忽略"
    continue
  fi

  # 防抖：10 秒内多次 publish 只构建一次
  if [[ -f /tmp/rebuild.lock ]] && (( $(date +%s) - $(stat -c %Y /tmp/rebuild.lock) < 10 )); then
    log "防抖中，跳过"
    continue
  fi
  touch /tmp/rebuild.lock
  rebuild || log "rebuild 失败"
done
