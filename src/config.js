const config = {
  port: parseInt(process.env.PORT, 10) || 3000,
  appVersion: process.env.APP_VERSION || 'v1.0.0',
  appColor: (process.env.APP_COLOR || 'blue').toLowerCase(),
  // Version 2 / Green activates the Prestige Ascension system
  prestigeEnabled: process.env.PRESTIGE_ENABLED === 'true' || (process.env.APP_COLOR || 'blue').toLowerCase() === 'green',
  
  redis: {
    host: process.env.REDIS_HOST || '127.0.0.1',
    port: parseInt(process.env.REDIS_PORT, 10) || 6379,
    password: process.env.REDIS_PASSWORD || undefined,
    retryStrategy(times) {
      const delay = Math.min(times * 200, 2000);
      return delay;
    }
  },
  
  podName: process.env.HOSTNAME || 'local-instance',
  nodeEnv: process.env.NODE_ENV || 'development'
};

module.exports = config;
