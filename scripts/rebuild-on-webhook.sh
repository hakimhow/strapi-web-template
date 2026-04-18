#!/usr/bin/env bash
# Webhook 接收器 —— 在 VPS 上以 systemd 服务运行，收到 Strapi 发布事件后重建 dist/
#
# 这里用 python3 的 http.server 作接收端（Linux 预装），避免装 ncat/webhook 等第三方工具。
# 如果 VPS 没 python3，可用 `docker run --rm node:20-alpine node -e ...` 替代。
#
# 安装（在 VPS 上执行一次，可通过 Portainer 的 Exec 或 VPN SSH）：
#   sudo cp scripts/rebuild-on-webhook.sh /usr/local/bin/
#   sudo cp scripts/rebuild-on-webhook.service /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now rebuild-on-webhook

set -euo pipefail
PORT="${WEBHOOK_PORT:-9999}"
SITE_PATH="${SITE_PATH:-/srv/example-site}"
SECRET="${WEBHOOK_SECRET:-}"

log() { echo "[$(date -Iseconds)] $*"; }

# 防抖：10 秒内多次触发合并成一次
DEBOUNCE_FILE=/tmp/rebuild.trigger
REBUILD_RUNNING=/tmp/rebuild.running

rebuild() {
  [[ -f "$REBUILD_RUNNING" ]] && { log "已有 rebuild 在跑，跳过"; return; }
  touch "$REBUILD_RUNNING"
  trap 'rm -f "$REBUILD_RUNNING"' EXIT

  log "开始 rebuild"
  cd "$SITE_PATH"
  set -a; source .env; set +a

  # 在容器里构建，避免污染宿主机
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

  if [[ -d dist ]]; then mv dist "dist.old.$(date +%s)"; fi
  mv apps/web/dist dist
  ls -dt dist.old.* 2>/dev/null | tail -n +3 | xargs -r rm -rf
  log "rebuild 完成"
}

# 防抖消费循环
watcher() {
  while true; do
    if [[ -f "$DEBOUNCE_FILE" ]]; then
      sleep 10   # 积攒 10 秒内的触发
      rm -f "$DEBOUNCE_FILE"
      rebuild || log "rebuild 失败"
    fi
    sleep 1
  done
}

# HTTP 接收器（python 原生，不依赖额外包）
receiver() {
  log "监听 127.0.0.1:$PORT"
  python3 -c "
import http.server, os
SECRET = os.environ.get('SECRET', '')
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        sig = self.headers.get('X-Strapi-Signature', '')
        if SECRET and sig != SECRET:
            self.send_response(403); self.end_headers(); return
        with open('${DEBOUNCE_FILE}', 'w') as f: f.write('go')
        self.send_response(202); self.end_headers(); self.wfile.write(b'queued')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', ${PORT}), H).serve_forever()
"
}

watcher &
SECRET="$SECRET" receiver
