// Punto de entrada: pone a escuchar la app definida en app.js
const config = require('./config');
const app = require('./app');

// Start Server
const server = app.listen(config.port, () => {
  console.log(`==============================================`);
  console.log(` Shape Popper Game Server Started             `);
  console.log(` Version:  ${config.appVersion} (${config.appColor.toUpperCase()})`);
  console.log(` Pod Host: ${config.podName}`);
  console.log(` Port:     ${config.port}`);
  console.log(` Prestige: ${config.prestigeEnabled ? 'ENABLED (v2)' : 'DISABLED (v1)'}`);
  console.log(` Redis:    ${config.redis.host}:${config.redis.port}`);
  console.log(`==============================================`);
});

// Graceful Shutdown for Kubernetes Pod Terminations
const handleShutdown = (signal) => {
  console.log(`[Server] Received ${signal}. Shutting down gracefully...`);
  server.close(() => {
    console.log('[Server] HTTP server closed.');
    process.exit(0);
  });
};

process.on('SIGTERM', () => handleShutdown('SIGTERM'));
process.on('SIGINT', () => handleShutdown('SIGINT'));
