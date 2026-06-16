require('./tracing');
const express = require('express');
const Redis = require('ioredis');

const app = express();
app.use(express.json());
const PORT = 4003;

const redis = new Redis({ host: 'redis', port: 6379, lazyConnect: true, retryStrategy: () => 2000 });
redis.connect().catch(() => {});

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.post('/notify', async (req, res) => {
  const { type, userId, orderId, email } = req.body || {};
  const notification = { type, userId, orderId, email, sentAt: new Date().toISOString() };

  try {
    await redis.lpush('notifications:queue', JSON.stringify(notification));
    await redis.incr(`notifications:count:${type || 'unknown'}`);
  } catch {}

  // Simulate processing delay (email sending, push notification, etc.)
  const delay = 20 + Math.floor(Math.random() * 80);
  await new Promise((r) => setTimeout(r, delay));

  // 2% failure rate
  if (Math.random() < 0.02) {
    return res.status(500).json({ error: 'notification delivery failed' });
  }

  res.json({ status: 'sent', notification });
});

app.get('/notifications/stats', async (_req, res) => {
  try {
    const queueLen = await redis.llen('notifications:queue');
    const orderCount = parseInt(await redis.get('notifications:count:order_confirmed') || '0', 10);
    const paymentCount = parseInt(await redis.get('notifications:count:payment_processed') || '0', 10);
    res.json({ queueLength: queueLen, orderConfirmed: orderCount, paymentProcessed: paymentCount });
  } catch (err) {
    res.json({ queueLength: 0, error: err.message });
  }
});

app.listen(PORT, () => console.log(`[notifications] listening on :${PORT}`));
