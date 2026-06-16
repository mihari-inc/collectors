require('./tracing');
const express = require('express');
const Redis = require('ioredis');

const app = express();
const PORT = 4001;

const redis = new Redis({ host: 'redis', port: 6379, lazyConnect: true, retryStrategy: () => 2000 });
redis.connect().catch(() => {});

const USERS = [
  { id: 1, name: 'Alice Martin', email: 'alice@example.com', role: 'admin' },
  { id: 2, name: 'Bob Chen', email: 'bob@example.com', role: 'developer' },
  { id: 3, name: 'Carol Davis', email: 'carol@example.com', role: 'designer' },
  { id: 4, name: 'David Kim', email: 'david@example.com', role: 'devops' },
  { id: 5, name: 'Eve Johnson', email: 'eve@example.com', role: 'manager' },
];

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/users', async (_req, res) => {
  try {
    const cached = await redis.get('users:all');
    if (cached) return res.json(JSON.parse(cached));
  } catch {}
  await redis.set('users:all', JSON.stringify(USERS), 'EX', 30).catch(() => {});
  res.json(USERS);
});

app.get('/users/:id', async (req, res) => {
  const id = parseInt(req.params.id, 10);
  const key = `users:${id}`;
  try {
    const cached = await redis.get(key);
    if (cached) return res.json(JSON.parse(cached));
  } catch {}
  const user = USERS.find((u) => u.id === id);
  if (!user) return res.status(404).json({ error: 'not found' });
  await redis.set(key, JSON.stringify(user), 'EX', 60).catch(() => {});
  res.json(user);
});

app.listen(PORT, () => console.log(`[users] listening on :${PORT}`));
