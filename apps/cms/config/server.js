module.exports = ({ env }) => ({
  host: env('HOST', '0.0.0.0'),
  port: env.int('PORT', 1337),
  app: {
    keys: env.array('APP_KEYS'),
  },
  url: env('PUBLIC_STRAPI_URL', ''),
  // 生产环境前面有 nginx / Cloudflare Tunnel —— 信任 X-Forwarded-* 头
  proxy: env.bool('IS_PROXIED', true),
});
