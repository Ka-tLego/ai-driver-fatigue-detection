# Backend API & Database

Node.js + Express + MongoDB (Mongoose). Receives monitoring data from the Flutter app,
stores it, and lets the app retrieve it. It does **not** detect fatigue itself - the app
decides the fatigue level and sends it; the backend stores it as-is (after validation).

## Run
Requirements: Node.js 18+, MongoDB Community Server running locally.
```powershell
cd backend
Copy-Item .env.example .env   # skip if .env already exists
npm install
npm run dev                   # or: npm start
```
Health check: `http://localhost:3000/api/health`. `EADDRINUSE` means it is already running on that port.

## Dashboard
Open `http://localhost:3000/dashboard/` (or `https://<render-url>/dashboard/`). It shows fatigue
events by time of day and time into the drive, a danger map, a break recommendation, heart rate
before events, a per-drive timeline and recent events.

"Dangerous" is ranked by **events per driving hour**, not raw counts, so times with more driving
don't look riskier just because of that. Slots with under 60 minutes of driving are shown as
"not enough data". Links can set filters: `/dashboard/?days=7&demo=1&measure=rate`.

**Password:** set `DASHBOARD_PASSWORD` (in `.env` locally, or in Render's environment variables).
The browser asks for it; any username works. It also protects every `GET /api/...` data route.
The app's `POST`/`PATCH` routes and `/api/health` stay open so phones and uptime checks keep working.

## Scripts
- `npm test` - automated API tests (no database needed; uses an in-memory stand-in for the models)
- `npm run seed` - posts sample data to the running backend to check storage end to end
- `npm run demo:add` - adds 4 weeks of realistic fake drives (marked as demo) so the dashboard has data;
  tick "Include demo data" on the dashboard to see them. `-- --days 14` for fewer days,
  `-- --uri "mongodb+srv://..."` to target another database (e.g. Atlas)
- `npm run demo:remove` - deletes all demo drives with their readings and events (real data is never touched)

## Endpoints (all JSON; responses are `{ success, message?, data }`)
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | Server check |
| POST | `/api/sessions` | Start session `{ pilotId?, notes? }` -> stores `startedAt`, status `active` |
| GET | `/api/sessions` | List sessions (newest first, max 100) |
| GET | `/api/sessions/:id` | Session + its readings + events |
| GET | `/api/sessions/:id/summary` | Duration, reading/event counts, averages, level counts, peak level |
| PATCH | `/api/sessions/:id` | Update `status` (`active`/`paused`/`ended`), `autopilotStatus` (`unknown`/`on`/`off`), `notes`. `ended` sets `endedAt`. |
| POST | `/api/sessions/:id/readings` | Store reading: `heartRateBpm`, `blinkRatePerMinute`, `ear` (0..1), `fatigueLevel` (`normal`/`warning`/`high`/`critical`), `fatigueScore` (0..100), `source`, `recordedAt` (all optional). 409 if session ended. |
| GET | `/api/sessions/:id/readings?limit=100` | Stored readings, newest first |
| POST | `/api/events` | Store event `{ sessionId, severity: Warning/High/Critical, message, fatigueLevel?, occurredAt?, heartRateBpm?, blinkRatePerMinute?, ear?, closureSeconds? }` |
| GET | `/api/events?sessionId=...` | Stored events, newest first |
| GET | `/api/limits` | Break interval + high-risk periods for the app's advisories (public; last 90 days; `?includeDemo=true`, or `LIMITS_INCLUDE_DEMO=true`, includes demo data) |
| GET | `/api/analytics/overview?days=30&includeDemo=true` | All dashboard figures (password) |
| GET | `/api/analytics/sessions` | Recent drives for the timeline picker (password) |
| GET | `/api/analytics/sessions/:id/timeline` | One drive's readings (averaged) and events (password) |

`POST /api/sessions` also accepts `startedAt` (when monitoring really started). GET routes need the
dashboard password when `DASHBOARD_PASSWORD` is set.

Errors: 400 invalid input, 404 not found, 409 session ended, 500 server error.
Database design: see `DATABASE.md`.

## .env
`PORT` (3000), `MONGODB_URI` (`mongodb://127.0.0.1:27017/pilot_fatigue`), `CORS_ORIGIN` (optional),
`DASHBOARD_PASSWORD` (optional locally, set it when hosted), `DASHBOARD_TIMEZONE` (`Africa/Johannesburg`).
