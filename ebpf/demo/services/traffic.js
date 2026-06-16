const http = require('http');

const GATEWAY = process.env.GATEWAY_URL || 'http://gateway:4000';
const INTERVAL_MS = parseInt(process.env.TRAFFIC_INTERVAL_MS || '800', 10);

function get(path) {
  return new Promise((resolve, reject) => {
    http.get(`${GATEWAY}${path}`, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    }).on('error', reject);
  });
}

function post(path, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const u = new URL(`${GATEWAY}${path}`);
    const opts = { hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': data.length } };
    const r = http.request(opts, (res) => {
      let d = '';
      res.on('data', (c) => { d += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    r.on('error', reject);
    r.write(data);
    r.end();
  });
}

const ITEMS = ['widget', 'gadget', 'gizmo', 'doohickey', 'thingamajig'];
const SCENARIOS = [
  { weight: 30, name: 'list-users', fn: () => get('/api/users') },
  { weight: 20, name: 'get-user', fn: () => get(`/api/users/${1 + Math.floor(Math.random() * 5)}`) },
  { weight: 15, name: 'list-orders', fn: () => get('/api/orders') },
  { weight: 25, name: 'create-order', fn: () => post('/api/orders', {
    userId: 1 + Math.floor(Math.random() * 5),
    item: ITEMS[Math.floor(Math.random() * ITEMS.length)],
    amount: Math.round((5 + Math.random() * 95) * 100) / 100,
  })},
  { weight: 10, name: 'dashboard', fn: () => get('/api/dashboard') },
];

const weightedScenarios = [];
for (const s of SCENARIOS) {
  for (let i = 0; i < s.weight; i++) weightedScenarios.push(s);
}

let total = 0;
let errors = 0;

async function tick() {
  const scenario = weightedScenarios[Math.floor(Math.random() * weightedScenarios.length)];
  try {
    const result = await scenario.fn();
    total++;
    if (result.status >= 400) errors++;
    if (total % 50 === 0) {
      console.log(`[traffic] ${total} requests, ${errors} errors (${((errors / total) * 100).toFixed(1)}%)`);
    }
  } catch (err) {
    errors++;
    total++;
  }
}

async function run() {
  console.log(`[traffic] Starting traffic generator → ${GATEWAY} (interval: ${INTERVAL_MS}ms)`);

  // Wait for gateway to be ready
  for (let i = 0; i < 30; i++) {
    try {
      await get('/health');
      console.log('[traffic] Gateway is ready');
      break;
    } catch {
      console.log('[traffic] Waiting for gateway...');
      await new Promise((r) => setTimeout(r, 2000));
    }
  }

  // Burst: 3 concurrent requests per tick for realistic load
  setInterval(async () => {
    const concurrent = 1 + Math.floor(Math.random() * 3);
    await Promise.allSettled(Array.from({ length: concurrent }, () => tick()));
  }, INTERVAL_MS);
}

run();
