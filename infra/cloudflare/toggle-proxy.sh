#!/usr/bin/env bash
# 一键切换所有站点记录的 CF proxy（橙云/灰云）状态
# 用法：
#   ./toggle-proxy.sh on  [env-file]   # 生产：开启 proxy
#   ./toggle-proxy.sh off [env-file]   # 开发/调试：仅 DNS

set -euo pipefail

MODE="${1:-}"
ENV_FILE="${2:-$(dirname "$0")/../../.env.production}"
# shellcheck disable=SC1090
source "$ENV_FILE"

case "$MODE" in
  on)  PROXIED=true ;;
  off) PROXIED=false ;;
  *) echo "用法: $0 on|off [env-file]"; exit 1 ;;
esac

export CF_PROXIED="$PROXIED"
exec "$(dirname "$0")/setup-dns.sh" "$ENV_FILE"
