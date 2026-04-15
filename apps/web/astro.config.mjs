import { defineConfig } from 'astro/config';

// SSG 模式：输出纯静态文件到 dist/
// 动态搜索由 nginx 把 /api/* 代理到 Strapi（同源，免 CORS）
export default defineConfig({
  output: 'static',
  site: process.env.PUBLIC_SITE_URL,
  build: {
    // 详情页等输出为 /articles/foo/index.html，便于 nginx 直出
    format: 'directory',
  },
});
