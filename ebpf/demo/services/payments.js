require('./tracing');
const express = require('express');
const http = require('http');
const { Pool } = require('pg');

const app = express();
app.use(express.json());
const PORT = 4004;

const pool = new Pool({
  host: 'postgres-demo',
  port: 5432,
  user: 'demo',
  password: 'demo',
  database: 'demo',
  max: 3,
});

function postJson(url, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const u = new URL(url);
    const opts = { hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': data.length } };
    const r = http.request(opts, (res) => {
      let d = '';
      res.on('data', (c) => { d += c; });
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve(d); } });
    });
    r.on('error', reject);
    r.write(data);
    r.end();
  });
}

async function initDb() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS payments (
        id SERIAL PRIMARY KEY,
        order_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        amount NUMERIC(10,2) NOT NULL,
        status VARCHAR(50) DEFAULT 'pending',
        provider VARCHAR(50) DEFAULT 'stripe',
        created_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);
  } catch (err) {
    console.error('[payments] DB init failed, retrying in 3s...', err.message);
    setTimeout(initDb, 3000);
  }
}
initDb();

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.post('/charge', async (req, res) => {
  const { orderId, userId, amount } = req.body || {};

  // Simulate payment processing
  const delay = 50 + Math.floor(Math.random() * 200);
  await new Promise((r) => setTimeout(r, delay));

  // 5% failure rate (card declined, timeout, etc.)
  if (Math.random() < 0.05) {
    return res.status(402).json({ error: 'payment declined', orderId });
  }

  try {
    const { rows } = await pool.query(
      'INSERT INTO payments (order_id, user_id, amount, status) VALUES ($1, $2, $3, $4) RETURNING *',
      [orderId || 0, userId || 0, amount || 0, 'completed'],
    );

    postJson('http://notifications:4003/notify', {
      type: 'payment_processed',
      userId,
      orderId,
      amount,
    }).catch(() => {});

    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => console.log(`[payments] listening on :${PORT}`));
