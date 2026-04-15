# Astro + Strapi Site Template —— SSG 分支

> 当前分支：**`ssg`** —— 纯静态生成，nginx 直出 `dist/`。
> SSR 版本在 `main` 分支：`git checkout main`。

## 两套方案怎么选

| 需求                                  | 建议分支 |
| ---                                   | ---      |
| 内容低频更新（每天 < 几十次）、以展示为主 | **ssg**  |
| 要求发布即可见、有用户登录/高频交互数据   | `main`   |
| 绝大多数企业官网、产品站、博客、案例展示   | **ssg**  |
| 电商/订单/实时库存                     | `main`   |

**本分支（ssg）核心差异**：
- 前端输出纯静态，**运行时没有 Node 进程**
- 动态搜索走 nginx `/api/*` 反代 Strapi（浏览器端 JS fetch，无服务端参与）
- 内容更新通过 Strapi webhook 触发重建（`scripts/rebuild-on-webhook.sh`）
- 部署产物是一个 `dist/` 目录（rsync），不是镜像 pull

## 技术栈

| 角色     | 技术                              |
| ---      | ---                               |
| 前端     | Astro（`output: 'static'`）       |
| CMS      | Strapi v4                         |
| 数据库   | PostgreSQL 16                     |
| 图片处理 | Imagor                            |
| 反向代理 | nginx（+ certbot DNS-01）         |
| DNS/CDN  | Cloudflare                        |
| 镜像仓库 | GHCR（仅 cms 镜像）               |
| 编排     | Docker Compose                    |

## 快速开始

```bash
# 选 SSG 分支
git clone git@github.com:you/new-site.git && cd new-site
git checkout ssg

./scripts/init-site.sh           # 交互式初始化
make dev                         # 本地开发：Astro dev server + Strapi + PG + Imagor

# 发布
./scripts/deploy.sh staging      # 本地服务器预览
./scripts/deploy.sh production   # 远程 VPS
```

## 重要：内容发布流程（SSG 特有）

客户在 Strapi 后台**发布新文章**后：

1. Strapi 触发 webhook → `https://<site>/hooks/rebuild`
2. 远程服务器上的 `rebuild-on-webhook.sh` 接到请求
3. 在临时容器里 `npm run build`（拉最新 Strapi 数据）
4. 原子替换 `dist/` → nginx 立即看到新内容（~30s–2min）

**第一次部署后必须做的配置**：
1. Strapi admin → Settings → Webhooks → Create new webhook
   - URL: `https://<site>/hooks/rebuild`
   - Events: `entry.publish` / `entry.update` / `entry.unpublish`
   - Header: `X-Strapi-Signature: <与 systemd service 里的 WEBHOOK_SECRET 一致>`
2. 在远程服务器安装 rebuild 服务：
   ```bash
   sudo cp scripts/rebuild-on-webhook.sh /usr/local/bin/
   sudo cp scripts/rebuild-on-webhook.service /etc/systemd/system/
   sudo systemctl enable --now rebuild-on-webhook
   ```

## 目录说明

```
apps/web      Astro SSG（output: static）
apps/cms      Strapi v4
infra/docker  compose 文件（base 里没有 web 服务）
infra/nginx   conf.d 里 root /srv/www，/api/ 代理 Strapi
scripts/
  init-site.sh              交互式初始化
  deploy.sh                 本地 build → rsync dist/ → compose up
  rebuild-on-webhook.sh     接收 Strapi webhook → 原子重建
  sync-db.sh                本地 ↔ 远程数据库同步
```

## 常用命令

```bash
make dev          # 本地开发（Astro dev 热重载 + Strapi）
make logs         # 跟踪日志
make deploy-staging
make deploy-prod
make dns-off      # 调试时关闭 CF proxy，直连源站
make dns-on       # 恢复 CF proxy
```

## 几个提醒

- **搜索限流**：`prod.conf` 已配 10 r/s per IP。如果客户站有爬虫嫌疑，把 `/api/` location 改成需要 token（`proxy_set_header Authorization`）或直接关掉。
- **草稿预览**：SSG 不支持。如果客户需要预览未发布内容，切回 `main`（SSR）或单独跑一个 Node 预览服务。
- **文章数量上限**：`getStaticPaths` 一次拉 1000 条。如果预期超过，改分页或上 `@astrojs/db` 的增量构建。
- **首次部署顺序**：第一次发布时 Strapi 还没起，`npm run build` 会拉不到数据。解决办法：先跑一次让 cms 起来（可手动 `docker compose up -d cms postgres`），再运行完整 `deploy.sh`。
