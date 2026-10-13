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

## Scripts
- `npm test` - automated API tests (no database needed; uses an in-memory stand-in for the models)
- `npm run seed` - posts sample data to the running backend to check storage end to end

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
| POST | `/api/events` | Store event `{ sessionId, severity: Warning/High/Critical, message, fatigueLevel? }` |
| GET | `/api/events?sessionId=...` | Stored events, newest first |

Errors: 400 invalid input, 404 not found, 409 session ended, 500 server error.
Database design: see `DATABASE.md`.

## .env
`PORT` (3000), `MONGODB_URI` (`mongodb://127.0.0.1:27017/pilot_fatigue`), `CORS_ORIGIN` (optional).
