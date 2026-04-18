// Strapi v5 —— i18n 已内置，不再需要单独的 plugin。
// 这里保留 upload 配置；其余按需扩展。
module.exports = ({ env }) => ({
  upload: {
    config: {
      provider: 'local',
      providerOptions: { sizeLimit: 200 * 1024 * 1024 },
    },
  },
});
