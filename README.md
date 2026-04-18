# strapi-web-template

通用可复制的网站模板 —— Astro + Strapi CMS + PostgreSQL + Imagor，
本地 Docker 开发，nginx 反代，Cloudflare，通过 GHCR 部署到 VPS。

仓库：<https://github.com/hakimhow/strapi-web-template>

## 两个分支 —— 按客户需求选

| 分支       | 渲染模式 | 运行时        | 适合场景                                   |
| ---        | ---      | ---           | ---                                        |
| **`main`** | Astro SSR（Node） | web 容器常驻 | 发布即可见、动态数据多、需要草稿预览         |
| **`ssg`**  | Astro SSG（纯静态）| 只 nginx 出 dist/ | 官网/产品站/博客/案例 —— 低频更新、要求快 |

克隆后 `git checkout ssg` 切换到静态方案。两个分支目录结构一致，只在 `apps/web`、compose、nginx、deploy 脚本上有差异。

## 技术栈

| 角色         | 技术                              |
| ---          | ---                               |
| 前端         | Astro (Node SSR)                  |
| CMS          | Strapi v5（扁平响应 + documentId）|
| 数据库       | PostgreSQL 16                     |
| 图片处理     | Imagor                            |
| 反向代理     | nginx (+ certbot)                 |
| DNS/CDN      | Cloudflare (dev: DNS only, prod: proxied) |
| 镜像仓库     | GitHub Container Registry (ghcr.io) |
| 编排         | Docker Compose                    |

## 快速开始 —— 新建一个站

```bash
# 1. 在 GitHub 上点击 "Use this template" 创建新站仓库，再 clone：
#    https://github.com/hakimhow/strapi-web-template → Use this template
git clone git@github.com:<your-user>/<new-site>.git && cd <new-site>

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
