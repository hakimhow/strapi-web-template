import { defineConfig } from 'astro/config';
import node from '@astrojs/node';

export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'standalone' }),
  server: {
    host: true,
    port: Number(process.env.PORT) || 3000,
  },
  site: process.env.PUBLIC_SITE_URL,
  vite: {
    ssr: {
      // 防止 SSR 打包时把 Strapi 客户端视为纯 ESM 问题
      noExternal: [],
    },
  },
});
