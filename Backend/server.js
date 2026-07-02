const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 8080;

app.use(cors());
app.use(express.json());

// Database connection is built from environment variables that are
// injected via a Kubernetes ConfigMap (non-sensitive) and a Kubernetes
// Secret (sensitive: username/password). See k8s/backend-configmap.yaml
// and k8s/backend-secret-example.yaml.
let pool = null;
function getPool() {
  if (!process.env.DB_HOST) return null;
  if (!pool) {
    pool = new Pool({
      host: process.env.DB_HOST,
      port: process.env.DB_PORT || 5432,
      database: process.env.DB_NAME,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      ssl: { rejectUnauthorized: false },
      connectionTimeoutMillis: 3000,
    });
  }
  return pool;
}

// Liveness/readiness endpoint
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/', (req, res) => {
  res.status(200).json({ message: 'Backend API is running', service: 'backend', port: PORT });
});

// Example endpoint that talks to the private database
app.get('/api/db-check', async (req, res) => {
  const p = getPool();
  if (!p) {
    return res.status(200).json({ db: 'not configured' });
  }
  try {
    const result = await p.query('SELECT NOW() as now');
    res.status(200).json({ db: 'connected', time: result.rows[0].now });
  } catch (err) {
    res.status(500).json({ db: 'error', message: err.message });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Backend listening on port ${PORT}`);
});

module.exports = app;