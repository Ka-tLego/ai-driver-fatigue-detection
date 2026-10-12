require('dotenv').config();
const app = require('./app');
const connectDB = require('./config/db');

const PORT = Number(process.env.PORT || 3000);

async function start() {
  try {
    await connectDB();
    // Bind to all interfaces so a phone on the same LAN can connect.
    const server = app.listen(PORT, '0.0.0.0', () => {
      console.log(`Fatigue backend listening on port ${PORT}`);
      console.log(`Health check: http://localhost:${PORT}/api/health`);
    });
    server.on('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        console.error(`\nPort ${PORT} is already in use - the backend is probably already running.`);
        console.error(`Check http://localhost:${PORT}/api/health, or stop the old one, or set a different PORT in .env.`);
        console.error(`Find it on Windows: Get-NetTCPConnection -LocalPort ${PORT} -State Listen`);
        process.exit(1);
      }
      throw err;
    });
  } catch (error) {
    console.error('Failed to start backend:', error.message);
    process.exit(1);
  }
}

start();
