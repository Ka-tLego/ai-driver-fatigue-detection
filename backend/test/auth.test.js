// Dashboard password: reads need it, the app's writes do not.
const test = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');

require('./fakeModels').install();
process.env.DASHBOARD_PASSWORD = 'secret-pass';
const app = require('../src/app');

const basic = (pw) => `Basic ${Buffer.from(`user:${pw}`).toString('base64')}`;

test('dashboard and data reads require the password', async () => {
  assert.equal((await request(app).get('/dashboard/')).status, 401);
  assert.equal((await request(app).get('/dashboard/').set('Authorization', basic('wrong'))).status, 401);
  assert.equal((await request(app).get('/dashboard/').set('Authorization', basic('secret-pass'))).status, 200);
  assert.equal((await request(app).get('/api/analytics/overview')).status, 401);
  assert.equal((await request(app).get('/api/sessions')).status, 401);
  assert.equal((await request(app).get('/api/sessions').set('Authorization', basic('secret-pass'))).status, 200);
  const res = await request(app).get('/api/events');
  assert.equal(res.status, 401);
  assert.match(res.headers['www-authenticate'], /Basic/);
});

test('health and the app\'s writes stay open', async () => {
  assert.equal((await request(app).get('/api/health')).status, 200);
  const s = await request(app).post('/api/sessions').send({ startedAt: new Date(Date.now() - 60000).toISOString() });
  assert.equal(s.status, 201);
  const ev = await request(app).post('/api/events').send({
    sessionId: s.body.data._id, severity: 'High', message: 'test', heartRateBpm: 61, closureSeconds: 1.4,
    occurredAt: new Date().toISOString(),
  });
  assert.equal(ev.status, 201);
  assert.equal(ev.body.data.closureSeconds, 1.4);
  const bad = await request(app).post('/api/events').send({ sessionId: s.body.data._id, severity: 'High', message: 't', occurredAt: '2099-01-01' });
  assert.equal(bad.status, 400);
});
