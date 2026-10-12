# Database design (MongoDB, database `pilot_fatigue`)

Three collections linked by `sessionId`.

```
monitoringsessions 1 ──< sensorreadings
                   1 ──< fatigueevents
```

## monitoringsessions - one document per monitoring session
| Field | Type | Notes |
|---|---|---|
| _id | ObjectId | session ID used by the app |
| pilotId | String, required | default `pilot-001` |
| status | `active` / `paused` / `ended` | monitoring state |
| autopilotStatus | `unknown` / `on` / `off` | |
| notes | String | |
| startedAt | Date | session start timestamp |
| endedAt | Date / null | set when status becomes `ended` |
| createdAt, updatedAt | Date | automatic |

## sensorreadings - time series of measurements
| Field | Type | Notes |
|---|---|---|
| sessionId | ObjectId, required, indexed | -> monitoringsessions |
| heartRateBpm | Number >= 0 | |
| blinkRatePerMinute | Number >= 0 | |
| ear | Number 0..1 | eye aspect ratio |
| fatigueLevel | `normal` / `warning` / `high` / `critical` | |
| fatigueScore | Number 0..100 | optional |
| source | String | default `flutter_app` |
| recordedAt | Date | timestamp of the reading |
Index: `{ sessionId: 1, recordedAt: -1 }`.

## fatigueevents - Warning / High / Critical alerts
| Field | Type | Notes |
|---|---|---|
| sessionId | ObjectId, required, indexed | -> monitoringsessions |
| severity | `Warning` / `High` / `Critical`, required | |
| message | String, required | |
| fatigueLevel | `normal` / `warning` / `high` / `critical` | optional |
| occurredAt | Date | event timestamp |
