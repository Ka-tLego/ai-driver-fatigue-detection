// Minimal in-memory stand-ins for the Mongoose models so the API can be tested
// without a running MongoDB. Supports only what the routes use.
const crypto = require('crypto');
const path = require('path');

function makeModel(defaults) {
  const rows = [];
  const matches = (row, filter) =>
    Object.entries(filter || {}).every(([k, v]) => String(row[k]) === String(v));

  class Query {
    constructor(list) { this.list = list; }
    sort(spec) {
      const [[key, dir]] = Object.entries(spec);
      this.list = [...this.list].sort((a, b) => (new Date(a[key]) - new Date(b[key])) * dir);
      return this;
    }
    limit(n) { this.list = this.list.slice(0, n); return this; }
    then(res, rej) { return Promise.resolve(this.list).then(res, rej); }
  }
  class SingleQuery extends Query {
    then(res, rej) { return Promise.resolve(this.list[0] || null).then(res, rej); }
  }

  return {
    _rows: rows,
    async create(doc) {
      const row = { _id: crypto.randomBytes(12).toString('hex'), createdAt: new Date(), ...defaults(), ...doc };
      for (const k of Object.keys(row)) if (row[k] === undefined) delete row[k];
      rows.push(row);
      return row;
    },
    findById(id) { return new SingleQuery(rows.filter((r) => r._id === String(id))); },
    findOne(filter) { return new SingleQuery(rows.filter((r) => matches(r, filter))); },
    find(filter) { return new Query(rows.filter((r) => matches(r, filter))); },
    async findByIdAndUpdate(id, update) {
      const row = rows.find((r) => r._id === String(id));
      if (!row) return null;
      Object.assign(row, update);
      return row;
    },
  };
}

function install() {
  const dir = path.join(__dirname, '..', 'src', 'models');
  const inject = (name, model) => {
    const file = require.resolve(path.join(dir, name));
    require.cache[file] = { id: file, filename: file, loaded: true, exports: model };
  };
  const models = {
    MonitoringSession: makeModel(() => ({ status: 'active', autopilotStatus: 'unknown', notes: '', startedAt: new Date(), endedAt: null })),
    SensorReading: makeModel(() => ({ recordedAt: new Date(), reasons: [] })),
    FatigueEvent: makeModel(() => ({ occurredAt: new Date() })),
  };
  Object.entries(models).forEach(([n, m]) => inject(n, m));
  return models;
}

module.exports = { install };
