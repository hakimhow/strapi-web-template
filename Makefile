SHELL := /usr/bin/env bash

ENV     ?= local
COMPOSE := docker compose --env-file .env.$(ENV) \
           -f infra/docker/compose.base.yml \
           -f infra/docker/compose.$(ENV).yml

.PHONY: dev up down logs ps build push shell-web shell-cms db-shell clean init deploy-staging deploy-prod dns-on dns-off

init:         ## 交互式初始化新站
	@bash scripts/init-site.sh

dev:          ## 启动本地开发环境
	@$(MAKE) ENV=local up

up:           ## 启动当前 ENV 的服务
	@$(COMPOSE) up -d
	@$(COMPOSE) ps

down:         ## 停止服务
	@$(COMPOSE) down

logs:         ## 跟踪日志
	@$(COMPOSE) logs -f --tail=100

ps:
	@$(COMPOSE) ps

build:        ## 本地构建镜像
	@docker build -t $${GHCR_IMAGE_WEB:-web}:local apps/web
	@docker build -t $${GHCR_IMAGE_CMS:-cms}:local apps/cms

push:         ## 构建并推送到 GHCR（tag=git sha）
	@bash scripts/deploy.sh staging    # 用 staging 默认只构建，可调整

shell-web:
	@$(COMPOSE) exec web sh

shell-cms:
	@$(COMPOSE) exec cms sh

db-shell:
	@$(COMPOSE) exec postgres psql -U $$DB_USER -d $$DB_NAME

clean:        ## 清理本地卷（危险！）
	@$(COMPOSE) down -v

deploy-staging:
	@bash scripts/deploy.sh staging

deploy-prod:
	@bash scripts/deploy.sh production

dns-on:       ## 开启 CF proxy（生产态）
	@bash infra/cloudflare/toggle-proxy.sh on .env.production

dns-off:      ## 关闭 CF proxy（调试用）
	@bash infra/cloudflare/toggle-proxy.sh off .env.production

help:
	@awk 'BEGIN {FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
