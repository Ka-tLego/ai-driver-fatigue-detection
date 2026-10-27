// Shared request-body validation helpers. Each throws an Error with status 400.
function badRequest(message) {
  return Object.assign(new Error(message), { status: 400 });
}

function optionalNumber(value, name, { min, max } = {}) {
  if (value === undefined || value === null || value === '') return undefined;
  const n = Number(value);
  if (!Number.isFinite(n)) throw badRequest(`${name} must be a number.`);
  if (min !== undefined && n < min) throw badRequest(`${name} must be >= ${min}.`);
  if (max !== undefined && n > max) throw badRequest(`${name} must be <= ${max}.`);
  return n;
}

// Optional client timestamp; rejects invalid dates and dates more than 5 min in the future.
function optionalPastDate(value, name) {
  if (value === undefined || value === null || value === '') return undefined;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) throw badRequest(`${name} must be a valid date.`);
  if (d.getTime() > Date.now() + 5 * 60 * 1000) throw badRequest(`${name} cannot be in the future.`);
  return d;
}

module.exports = { badRequest, optionalNumber, optionalPastDate };
