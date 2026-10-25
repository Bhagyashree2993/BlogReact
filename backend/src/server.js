require('dotenv').config();
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const client = require('prom-client');

const { checkDbConnection } = require('./config/db');
const authRoutes = require('./routes/auth');
const postRoutes = require('./routes/posts');

const app = express();
const PORT = process.env.PORT || 5000;

// Running behind the AWS ALB + nginx: trust X-Forwarded-For so rate limiting sees real client IPs
app.set('trust proxy', 2);

// --- Prometheus metrics ---
const register = new client.Registry();
client.collectDefaultMetrics({ register });
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status'],
});
register.registerMetric(httpRequestDuration);

app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    // Use the matched route pattern (e.g. /api/posts/:slug) to keep label cardinality low
    const route = req.route ? `${req.baseUrl}${req.route.path}` : 'unmatched';
    end({ method: req.method, route, status: res.statusCode });
  });
  next();
});

// --- Middleware ---
app.use(helmet());
app.use(cors({ origin: process.env.CORS_ORIGIN || '*' }));
app.use(express.json({ limit: '1mb' }));
app.use(morgan('combined'));
app.use(
  '/api',
  rateLimit({ windowMs: 15 * 60 * 1000, max: 300, standardHeaders: true, legacyHeaders: false })
);

// --- Routes ---
app.use('/api/auth', authRoutes);
app.use('/api/posts', postRoutes);

// Kubernetes liveness probe
app.get('/healthz', (_req, res) => res.status(200).json({ status: 'ok' }));

// Kubernetes readiness probe - verifies DB connectivity
app.get('/readyz', async (_req, res) => {
  try {
    await checkDbConnection();
    res.status(200).json({ status: 'ready' });
  } catch (err) {
    res.status(503).json({ status: 'not-ready', error: err.message });
  }
});

// Prometheus scrape endpoint
app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.use((err, _req, res, _next) => {
  console.error(err.stack);
  res.status(500).json({ error: 'Internal server error' });
});

app.use((_req, res) => res.status(404).json({ error: 'Route not found' }));

if (require.main === module) {
  const server = app.listen(PORT, () => {
    console.log(`Blog API listening on port ${PORT}`);
  });

  // Graceful shutdown so Kubernetes rolling updates don't drop in-flight requests
  const shutdown = (signal) => {
    console.log(`${signal} received, closing server`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

module.exports = app;
