require('./tracing');
const express = require('express');
const http = require('http');

const app = express();
const PORT = 4000;

function fetch(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    }).on('error', reject);
  });
}

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/api/users', async (_req, res) => {
  try {
    const users = await fetch('http://users:4001/users');
    res.json(users);
  } catch (err) {
    res.status(502).json({ error: 'user-service unavailable' });
  }
});

app.get('/api/users/:id', async (req, res) => {
  try {
    const user = await fetch(`http://users:4001/users/${req.params.id}`);
    res.json(user);
  } catch (err) {
    res.status(502).json({ error: 'user-service unavailable' });
  }
});

app.get('/api/orders', async (_req, res) => {
  try {
    const orders = await fetch('http://orders:4002/orders');
    res.json(orders);
  } catch (err) {
    res.status(502).json({ error: 'order-service unavailable' });
  }
});

app.post('/api/orders', express.json(), async (req, res) => {
  try {
    const order = await new Promise((resolve, reject) => {
      const data = JSON.stringify(req.body || { userId: 1, item: 'widget', amount: 29.99 });
      const opts = { hostname: 'orders', port: 4002, path: '/orders', method: 'POST', headers: { 'Content-Type': 'application/json' } };
      const r = http.request(opts, (resp) => {
        let body = '';
        resp.on('data', (c) => { body += c; });
        resp.on('end', () => resolve(JSON.parse(body)));
      });
      r.on('error', reject);
      r.write(data);
      r.end();
    });
    res.status(201).json(order);
  } catch (err) {
    res.status(502).json({ error: 'order-service unavailable' });
  }
});

app.get('/api/dashboard', async (_req, res) => {
  try {
    const [users, orders] = await Promise.all([
      fetch('http://users:4001/users'),
      fetch('http://orders:4002/orders'),
    ]);
    res.json({ users: Array.isArray(users) ? users.length : 0, orders: Array.isArray(orders) ? orders.length : 0 });
  } catch (err) {
    res.status(502).json({ error: 'services unavailable' });
  }
});

app.listen(PORT, () => console.log(`[gateway] listening on :${PORT}`));
