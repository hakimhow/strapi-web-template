module.exports = ({ env }) => ({
  // 默认图片由 Strapi 存本地，imagor 读取同一卷进行处理
  upload: {
    config: {
      provider: 'local',
      providerOptions: { sizeLimit: 200 * 1024 * 1024 },
    },
  },
});
