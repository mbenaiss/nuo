# Santé and workouts

The bots answer questions about your shape (activity, heart, sleep, sessions, weight) by asking your iPhone at
the moment of the question, and they put structured training sessions on your Apple Watch. Both are device tools
(`docs/protocol.md`, « Device tools »): HealthKit and WorkoutKit run inside the iPhone app, the gateway only carries
the call and the answer.

```
 bot ──nuo MCP──▶ gateway POST /api/device/tools/health_* ──socket or silent push──▶ iPhone (HealthKit)
                                                                                  └──▶ answer ──▶ bot's turn only
 bot ──nuo MCP──▶ gateway POST /api/device/tools/workout_schedule ──▶ iPhone (WorkoutKit) ──▶ Fitness ──▶ Apple Watch
```

Nothing is stored. The gateway keeps, per device, only the list of tool names that device allows
(`device.capabilities.<deviceId>` in `meta`) — never a figure, a sample or a session. A health answer exists in the
turn that asked for it and in that conversation's transcript, like a weather answer.

The iPhone only. A Mac holds no Santé data and pairs with no watch, so `DeviceToolGroup.available` drops `.health` and
`.workouts` on macOS, the Mac never declares them, and the gateway's iPhone-first tiering never falls back to a Mac for
them. HealthKit samples are encrypted while the iPhone is locked: a request that lands on a locked iPhone answers
`Santé est verrouillé…`, which the bot passes on as it stands.

## Permissions

Three separate consents, all the user's:

| | Where | What it covers |
|---|---|---|
| Santé | the system sheet, per data type | Which of the types below Nuo may read. Nuo asks for read only — it declares no right to write to Santé. |
| Séances | the WorkoutKit sheet | Putting a session in Fitness, which syncs it to the watch. |
| Accès des bots | Nuo › Réglages › Accès des bots | Whether the bots may use each family at all, on top of the system's answer. |

Réglages › Accès des bots has a « Santé » and a « Séances » switch, each with the button that asks the system the
first time, and afterwards a link to Santé for changing data type by data type. The app declares the tools only while
the switch is on *and* the consent was given (`DeviceToolsCenter.isAuthorized`), so a bot is told to go and enable it
rather than getting an empty answer.

Santé never says what the user granted, only whether the question has been put
(`statusForAuthorizationRequest(toShare:read:)` → `.unnecessary`). So a refused type and a type with nothing recorded
read the same from the app's side: the figure is simply absent from the answer, and a missing day is never a zero.

Entitlement `com.apple.developer.healthkit`, usage key `NSHealthShareUsageDescription` (iPhone target only).
WorkoutKit needs no entitlement, no account and no key of its own.

## What the bots read

Read-only, declared once in `AppleHealthTools.readTypes`: steps, walking/running and cycling distance, active and
resting energy, exercise and stand minutes, flights climbed; heart rate with its daily minimum and maximum, resting
heart rate, HRV (SDNN), walking heart rate average, respiratory rate, VO2max; sleep analysis; workouts; body mass,
height, body fat, lean mass.

| Tool | |
|---|---|
| `health_summary` | The one-call overview: today's rings, the averages of the last days, last night, resting heart rate and HRV, the measurements, the latest sessions. |
| `health_activity` | Day by day: steps, distance, energy, exercise and stand minutes, flights, plus totals and averages. |
| `health_heart` | Day by day: resting bpm, HRV in ms, walking average, the day's low and high, breaths per minute, and the latest VO2max. |
| `health_sleep` | Night by night: when sleep started and ended, time asleep, deep / REM / core phases, minutes awake. |
| `health_workouts` | Sessions: type, start, duration, distance, average pace, energy, average and maximum heart rate, elevation, and the app that recorded it. Filter by `type`, English or French. |
| `health_body` | Weight and its change over the period, height, BMI, body fat, lean mass, VO2max, each dated. |

Every tool takes `days` (`nights` for sleep) or an explicit `start`/`end`, as whole local days, 400 days at most.
Figures reach the bot rounded the way one reads them: kilometres to two decimals, a pace as `4:38/km`, a duration as
`1 h 12`.

A night runs noon to noon, so what you sleep before midday counts for that morning, and the night carries the
date of the morning you woke up. Santé files one sample per stage *and per source*, so a night arrives as dozens of
overlapping pieces; `HealthSleep.nights` merges them before counting anything, which is why two sources recording the
same deep sleep do not double it. A source that only says « asleep », with no phases, still gives a total.

`HealthReport`, `HealthSleep` and `HealthRange` hold this shaping and carry no HealthKit import, so they are tested on
their own in `NuoMacTests` (`HealthReportTests`); `AppleHealthTools` is the HealthKit layer around them.

## Sessions on the Apple Watch

`workout_schedule` takes a session as a bot composes it and hands it to `WorkoutScheduler.shared.schedule`. It lands
in the iPhone's Fitness app and, from there, in the watch's own Exercice app, where the watch guides each step, holds
the pace alerts and records the result in Santé. Nuo's watch app has no part in it: the session runs in Apple's own
workout app, with its screens, its haptics and its metrics.

A session is an optional `warmup`, a list of `blocks`, and an optional `cooldown`. A block has `repeat` and the steps
of one repetition — the effort, then the recovery — which is how Fitness and the watch show intervals natively. A step
ends on a distance (`km` or `distance` in metres), a time (`minutes` or `duration` in seconds) or `open` (until the
wrist is tapped), and may carry a pace (`pace`, or `pace_fast`/`pace_slow` for a range) or a heart rate target
(`heart_rate_zone` 1–5, `heart_rate_min`/`heart_rate_max`).

`workout_scheduled` lists what is programmed, `workout_cancel` removes one by name or day (or all, after the user's
explicit go-ahead). WorkoutKit caps how many sessions may be scheduled at once
(`WorkoutScheduler.maxAllowedScheduledWorkoutCount`); past it, the tool says so instead of silently dropping one.

WorkoutKit traps rather than throws on a malformed plan, so `WorkoutDraftParser` refuses everything suspect first,
with a message the bot can act on: a range whose bounds are equal or inverted (the same pace twice becomes a single
threshold alert, an inverted pace range is put back in order), a heart rate ceiling without a floor (WorkoutKit wants
a positive lower bound, so it becomes `1...max`), a pace outside 2:00–30:00, a step with no end, an empty block, a
date in the past (brought back to now, or a bare day read as 9 am), and more than 50 steps, which the watch refuses.

Where the plan comes from is the bot's business: `health_workouts` and `health_heart` are there so a session is built
on what you actually run. Third-party training apps are not involved: they export their own sessions through the
same WorkoutKit path, from their own app.
