# SSG 模式 —— 该 Dockerfile 仅用于 CI/远程构建静态产物。
# 运行时不需要容器；nginx 直接服务 dist/。
#
# 用法：
#   docker build --target export --output=./dist apps/web
#   会把构建产物拷到主机 ./dist
FROM node:20-alpine AS build
WORKDIR /opt/app
ARG PUBLIC_SITE_URL
ARG PUBLIC_STRAPI_URL
ARG PUBLIC_IMAGOR_URL
ARG STRAPI_PUBLIC_TOKEN
ENV PUBLIC_SITE_URL=$PUBLIC_SITE_URL \
    PUBLIC_STRAPI_URL=$PUBLIC_STRAPI_URL \
    PUBLIC_IMAGOR_URL=$PUBLIC_IMAGOR_URL \
    STRAPI_PUBLIC_TOKEN=$STRAPI_PUBLIC_TOKEN
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# 纯产物阶段 —— 用 `--output` 导出
FROM scratch AS export
COPY --from=build /opt/app/dist /
