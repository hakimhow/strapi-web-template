# Astro + Strapi Site Template

通用可复制的网站模板 —— Astro SSR + Strapi CMS + PostgreSQL + Imagor，
本地 Docker 开发，nginx 反代，Cloudflare DNS，通过 GHCR 部署到 VPS。

## 技术栈

| 角色         | 技术                              |
| ---          | ---                               |
| 前端         | Astro (Node SSR)                  |
| CMS          | Strapi v4                         |
| 数据库       | PostgreSQL 16                     |
| 图片处理     | Imagor                            |
| 反向代理     | nginx (+ certbot)                 |
| DNS/CDN      | Cloudflare (dev: DNS only, prod: proxied) |
| 镜像仓库     | GitHub Container Registry (ghcr.io) |
| 编排         | Docker Compose                    |

## 快速开始 —— 新建一个站

```bash
# 1. 基于 template 创建新仓库（GitHub 网页 "Use this template"）
git clone git@github.com:you/new-site.git && cd new-site

# 2. 交互式初始化（会问域名、CF token、SSH key 等）
./scripts/init-site.sh

# 3. 本地开发
make dev
# → http://localhost:3000 (Astro)
# → http://localhost:1337/admin (Strapi)
# → http://localhost:8000 (Imagor)

# 4. 发到本地服务器测试
./scripts/deploy.sh staging

# 5. 客户确认后发到生产
./scripts/deploy.sh production
```

## 目录说明

```
apps/web     Astro 前端
apps/cms     Strapi CMS
infra/docker  compose 文件（base/dev/staging/prod 分层）
infra/nginx   nginx 配置 + 证书
infra/cloudflare  CF API 脚本（建 DNS、切换 proxy）
scripts       init / deploy / backup 脚本
```

详见各目录下的 README 或脚本开头注释。

## 环境变量

`.env.local`（本地）、`.env.staging`（本地服务器）、`.env.production`（远程 VPS）
由 `init-site.sh` 生成，**均已 gitignore**。敏感信息建议用 sops 加密后提交。

## 常用命令

```bash
make dev          # 本地开发
make logs         # 跟踪日志
make down         # 停止
make build        # 构建生产镜像
make push         # 推送到 GHCR
make shell-cms    # 进入 Strapi 容器
make db-shell     # 进入 psql
```
