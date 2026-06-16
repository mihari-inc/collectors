require('./tracing');
const express = require('express');
const http = require('http');
const { Pool } = require('pg');

const app = express();
app.use(express.json());
const PORT = 4002;

const pool = new Pool({
  host: 'postgres-demo',
  port: 5432,
  user: 'demo',
  password: 'demo',
  database: 'demo',
  max: 5,
});

function fetch(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve(data); } });
    }).on('error', reject);
  });
}

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
      CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL,
        item VARCHAR(255) NOT NULL,
        amount NUMERIC(10,2) NOT NULL,
        status VARCHAR(50) DEFAULT 'pending',
        created_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);
  } catch (err) {
    console.error('[orders] DB init failed, retrying in 3s...', err.message);
    setTimeout(initDb, 3000);
  }
}
initDb();

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/orders', async (_req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM orders ORDER BY created_at DESC LIMIT 50');
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/orders', async (req, res) => {
  const { userId = 1, item = 'widget', amount = 29.99 } = req.body || {};
  try {
    const user = await fetch(`http://users:4001/users/${userId}`);
    if (user.error) return res.status(400).json({ error: 'invalid user' });

    const { rows } = await pool.query(
      'INSERT INTO orders (user_id, item, amount, status) VALUES ($1, $2, $3, $4) RETURNING *',
      [userId, item, amount, 'confirmed'],
    );

    postJson('http://notifications:4003/notify', {
      type: 'order_confirmed',
      userId,
      orderId: rows[0].id,
      email: user.email,
    }).catch(() => {});

    postJson('http://payments:4004/charge', {
      orderId: rows[0].id,
      userId,
      amount,
    }).catch(() => {});

    res.status(201).json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/orders/stats', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT status, count(*) AS count, COALESCE(sum(amount), 0) AS total
      FROM orders GROUP BY status
    `);
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => console.log(`[orders] listening on :${PORT}`));
