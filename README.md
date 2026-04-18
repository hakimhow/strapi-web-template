# Astro + Strapi Site Template —— SSG 分支

> 当前分支：**`ssg`** —— 纯静态生成，nginx 直出 `dist/`，Cloudflare Tunnel 暴露。
> SSR 版本在 `main` 分支：`git checkout main`。

## 两套方案怎么选

| 需求                                     | 建议分支 |
| ---                                      | ---      |
| 官网 / 产品站 / 博客 / 案例展示           | **ssg**  |
| 内容低频更新（每天 < 几十次）、以展示为主  | **ssg**  |
| 发布即可见、高频交互数据 / 草稿预览       | `main`   |
| 电商 / 订单 / 实时库存                    | `main`   |

## 生产架构（无公网 IP VPS + Cloudflare Tunnel）

```
用户浏览器
    ↓
Cloudflare Edge（TLS 终结 + CDN + WAF）
    ↓  加密出站隧道
cloudflared 容器（在 VPS 内）
    ↓
nginx（HTTP only，80 端口不对外暴露）
    ↓
├── /            → dist/ 静态文件
├── /api/        → Strapi（限流 10 r/s）
└── cms./cdn.*   → Strapi / Imagor

管理面：你 → VPN → VPS（SSH 或 Portainer UI）
```

**为什么用 Tunnel 而不是 certbot + nginx TLS**：
- VPS 没公网 IP，Let's Encrypt 发不了证书
- Tunnel 不需要开防火墙端口、不需要 DNS A 记录
- CF 自动签发 SNI 证书，自动 CDN

## 技术栈

| 角色     | 技术                              |
| ---      | ---                               |
| 前端     | Astro（`output: 'static'`）       |
| CMS      | Strapi v4                         |
| 数据库   | PostgreSQL 16                     |
| 图片处理 | Imagor                            |
| 反向代理 | nginx（HTTP only，仅容器内网）    |
| 公网暴露 | Cloudflare Tunnel (`cloudflared`) |
| 镜像仓库 | GHCR（仅 cms 镜像）               |
| 编排     | Docker Compose / Portainer        |
| 日常管理 | VPN + SSH / Portainer Web UI      |

## 快速开始 —— 建一个新站

```bash
# 1. 基于模板创建（GitHub Use this template），clone 后切分支
git clone git@github.com:you/new-site.git && cd new-site
git checkout ssg

# 2. 交互式初始化：会问域名、CF Tunnel token、VPN 内 VPS 地址、SSH key 等
./scripts/init-site.sh

# 3. 本地开发
make dev
# → http://localhost:3000（Astro 热重载）
# → http://localhost:1337/admin（Strapi 后台）

# 4. 首次生产部署（两阶段）—— 必须 VPN 已连接
./scripts/deploy.sh production --cms-first
#   只起 postgres + cms + imagor + cloudflared
#   CF Tunnel 就绪后，https://cms.example.com/admin 可访问

# 在 Strapi admin：创建管理员 → 建只读 API token → 发布示例文章
# 把 token 填入 .env.production 的 STRAPI_PUBLIC_TOKEN

# 5. 完整部署
./scripts/deploy.sh production
#   本地 build 前端 → rsync dist/ → nginx 立即生效
```

## Cloudflare Tunnel 初始化（两种方式）

**方式 A（推荐，最简单）—— Dashboard 手动**

1. 打开 [Zero Trust → Networks → Tunnels](https://one.dash.cloudflare.com/)
2. Create a tunnel → Cloudflared → 命名为 `<site-slug>`
3. 复制 token（`eyJ...` 开头的一长串），运行 `init-site.sh` 时粘贴
4. 在 tunnel 的 **Public Hostnames** 里添加：

   | Subdomain | Domain      | Service            |
   | ---       | ---         | ---                |
   | (空)      | example.com | `http://nginx:80`  |
   | www       | example.com | `http://nginx:80`  |
   | cms       | example.com | `http://nginx:80`  |
   | cdn       | example.com | `http://nginx:80`  |

**方式 B —— CLI 自动化（要本机装 cloudflared 且已 login）**

```bash
./infra/cloudflare/setup-tunnel.sh .env.production
```

## 内容发布流程（SSG 特有）

客户在 Strapi 后台发布新文章后：

1. Strapi webhook → `https://<site>/hooks/rebuild`
2. 远程服务器 `rebuild-on-webhook.sh` 接收
3. 在临时容器里 `npm run build`（拉最新数据）
4. 原子替换 `dist/`，nginx 立即看到新内容（~30s–2min）

**部署后必做**：
1. Strapi admin → Settings → Webhooks → Create
   - URL: `https://<site>/hooks/rebuild`
   - Events: `entry.publish` / `entry.update` / `entry.unpublish`
   - Header: `X-Strapi-Signature: <WEBHOOK_SECRET>`
2. 在 VPS 上（通过 VPN SSH 或 Portainer Terminal）：
   ```bash
   sudo cp scripts/rebuild-on-webhook.sh /usr/local/bin/
   sudo cp scripts/rebuild-on-webhook.service /etc/systemd/system/
   sudo systemctl enable --now rebuild-on-webhook
   ```

## 目录说明

```
apps/web                      Astro SSG（output: static）
apps/cms                      Strapi v4
infra/docker/
  compose.base.yml              postgres + cms + imagor（共享）
  compose.dev.yml               本地开发叠加
  compose.staging.yml           本地服务器（nginx + 自签证书）
  compose.prod.yml              生产（nginx + cloudflared）
infra/nginx/conf.d/
  staging.conf                  HTTPS 自签（局域网访问）
  prod.conf                     HTTP only（CF 终结 TLS）
infra/cloudflare/
  setup-tunnel.sh               一键创建 tunnel + 绑 DNS
  tunnel-config.yml.example     模式 B 配置模板
scripts/
  init-site.sh                  交互式初始化
  deploy.sh                     两阶段部署（含 --cms-first）
  rebuild-on-webhook.sh         Strapi 发布触发重建
  sync-db.sh                    本地 ↔ 远程 DB 同步
```

## 常用命令

```bash
make dev            # 本地开发
make logs           # 跟踪日志
make build          # 本地构建前端 + cms 镜像
make deploy-staging
make deploy-prod
```

## Portainer 集成

部署后可把 VPS 上的 compose 纳入 Portainer 管理：

1. Portainer → Stacks → Add stack → **Repository** 或 **Upload**
2. Compose path：`infra/docker/compose.base.yml` + `infra/docker/compose.prod.yml`
3. Environment variables：上传 `.env.production`

之后容器重启、查看日志、回滚等都能在 Portainer UI 做，不必每次都 SSH。

## 已知限制与提示

- **草稿预览**：SSG 不支持。客户要预览未发布内容就切回 `main`
- **getStaticPaths 上限**：当前一次拉 1000 条文章，超过需改分页策略
- **健康检查走公共域名**：deploy.sh 末尾 curl 的是 `https://example.com`，如果 CF Tunnel 未就绪会失败 —— 首次等 1–2 分钟
- **回滚**：`ssh <host> "cd /srv/<site> && mv dist.old.<ts> dist"`（保留最近 2 份）
