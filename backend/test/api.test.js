const test = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');

require('./fakeModels').install();
const app = require('../src/app');

test('health', async () => {
  const h = await request(app).get('/api/health');
  assert.equal(h.status, 200);
  assert.equal(h.body.success, true);
});

test('session lifecycle, readings, events, summary', async () => {
  const created = await request(app).post('/api/sessions').send({ pilotId: 'pilot-9' });
  assert.equal(created.status, 201);
  const id = created.body.data._id;
  assert.equal(created.body.data.status, 'active');
  assert.ok(created.body.data.startedAt);

  const r1 = await request(app).post(`/api/sessions/${id}/readings`).send({ heartRateBpm: 75, blinkRatePerMinute: 16, ear: 0.3, fatigueLevel: 'normal' });
  assert.equal(r1.status, 201);
  assert.equal(r1.body.data.heartRateBpm, 75);
  assert.equal(r1.body.data.fatigueLevel, 'normal');
  assert.ok(r1.body.data.recordedAt);
  await request(app).post(`/api/sessions/${id}/readings`).send({ heartRateBpm: 50, blinkRatePerMinute: 35, ear: 0.12, fatigueLevel: 'critical' });

  const ev = await request(app).post('/api/events').send({ sessionId: id, severity: 'Critical', message: 'Eyes closed', fatigueLevel: 'critical' });
  assert.equal(ev.status, 201);

  assert.equal((await request(app).patch(`/api/sessions/${id}`).send({ status: 'paused', autopilotStatus: 'on' })).body.data.autopilotStatus, 'on');
  await request(app).patch(`/api/sessions/${id}`).send({ status: 'active' });

  const detail = await request(app).get(`/api/sessions/${id}`);
  assert.equal(detail.body.data.readings.length, 2);
  assert.equal(detail.body.data.events.length, 1);

  const sum = await request(app).get(`/api/sessions/${id}/summary`);
  assert.equal(sum.body.data.readingCount, 2);
  assert.equal(sum.body.data.eventCount, 1);
  assert.equal(sum.body.data.peakLevel, 'critical');
  assert.equal(sum.body.data.severityCounts.Critical, 1);

  assert.equal((await request(app).get(`/api/sessions/${id}/readings`)).body.data.length, 2);
  assert.equal((await request(app).get(`/api/events?sessionId=${id}`)).body.data.length, 1);

  const ended = await request(app).patch(`/api/sessions/${id}`).send({ status: 'ended' });
  assert.equal(ended.body.data.status, 'ended');
  assert.ok(ended.body.data.endedAt);
  assert.equal((await request(app).post(`/api/sessions/${id}/readings`).send({ ear: 0.3 })).status, 409);
  const list = await request(app).get('/api/sessions');
  assert.ok(list.body.data.length >= 1);
});

test('validation errors', async () => {
  const id = (await request(app).post('/api/sessions').send({})).body.data._id;
  const post = (b) => request(app).post(`/api/sessions/${id}/readings`).send(b);
  assert.equal((await post({ ear: 5 })).status, 400);
  assert.equal((await post({ heartRateBpm: 'abc' })).status, 400);
  assert.equal((await post({ fatigueLevel: 'bogus' })).status, 400);
  assert.equal((await post({ recordedAt: 'not-a-date' })).status, 400);
  assert.equal((await request(app).post('/api/sessions/nope/readings').send({})).status, 400);
  assert.equal((await request(app).post('/api/sessions/aaaaaaaaaaaaaaaaaaaaaaaa/readings').send({})).status, 404);
  assert.equal((await request(app).patch(`/api/sessions/${id}`).send({ status: 'bad' })).status, 400);
  assert.equal((await request(app).patch(`/api/sessions/${id}`).send({ autopilotStatus: 'bad' })).status, 400);
  assert.equal((await request(app).patch(`/api/sessions/${id}`).send({})).status, 400);
  assert.equal((await request(app).post('/api/events').send({ sessionId: id, severity: 'Low', message: 'x' })).status, 400);
  assert.equal((await request(app).post('/api/events').send({ sessionId: id, severity: 'High' })).status, 400);
  assert.equal((await request(app).get('/api/nothing')).status, 404);
});
