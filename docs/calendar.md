# Calendar and booking

Nuo replaces a calendar app: one merged agenda of every calendar you have on your Apple devices (iCloud, Google,
Exchange…) plus dated reminders, event creation, and Calendly-like booking pages (« Openings ») and proposals.

```
 Mac / iPhone (EventKit) ──PUT sources, POST sync──▶ gateway data.db ──GET events──▶ apps, widgets, agents (v_agenda)
 apps: create/edit events in EventKit ──▶ POST /api/calendar/sync/events (instant mirror)
 bookings, agents, POST /api/calendar/events ──gog──▶ Google Calendar (sends the invitations)
 rdv.<domain>/<slug> (public host) ──▶ free slots only ──▶ booking ──▶ Google event + push « 📅 Nouveau rendez-vous »
```

The gateway never reads Apple calendars itself: the apps bridge them. Writes you make in the apps go through
EventKit on the device (any calendar, whatever the account) and are mirrored back; the gateway's Google write path
(`gog`) is for bookings, agents and `POST /api/calendar/events`.

All times on the wire are ISO 8601 instants in UTC (`2026-10-20T07:30:00.000Z`). Working hours of booking types are
wall-clock times in `Europe/Paris`.

## Calendar bridge (apps → gateway)

The Mac is the primary bridge (always on), the iPhone a fallback. Both may push: see « Two devices » below.
All routes need the paired-device token (`app` scope). The device is the token's device, never a body field.

### `PUT /api/calendar/sources`

The full list of this device's EventKit calendars (event calendars only, not reminder lists). Calendars of this
device missing from the list are dropped with their events.

```json
{ "calendars": [
  { "id": "6F1C…",            // EKCalendar.calendarIdentifier
    "title": "Travail",
    "color": "#1BADF8",        // EKCalendar.cgColor as #RRGGBB
    "account": "alex@example.com",   // EKSource.title
    "type": "caldav",          // local | caldav | exchange | subscription | birthday
    "allowsModifications": true }
] }
```

Response `200`: `{ "calendars": [Calendar] }` (see Read API), so the device learns each calendar's `enabled` and
`privacy` before syncing.

### `POST /api/calendar/sync` (batched, idempotent)

```json
{ "syncId": "c2b1…",               // one id per full sync run, the same on every batch of that run
  "calendars": [
  { "calendarId": "6F1C…",          // calendarIdentifier, as in /sources
    "window": { "from": "2026-09-18T00:00:00Z", "to": "2027-04-16T00:00:00Z" },   // [-30 d, +180 d]
    "events": [Event],
    "deleted": ["<externalId>", "…"],
    "complete": true }               // last batch of this calendar for this syncId
] }
```

`Event` (bridge input; recurrences are expanded by the app, one entry per occurrence):

| field | type | notes |
|---|---|---|
| `externalId` | string | unique per occurrence: `calendarItemExternalIdentifier` (fallback `eventIdentifier`) + `@` + occurrence start ISO for recurring events |
| `seriesId` | string? | `calendarItemExternalIdentifier` of the series, for recurring events |
| `title` | string? | |
| `location` | string? | `structuredLocation.title` or `location` |
| `coordinates` | `{lat, lon}`? | `structuredLocation.geoLocation` |
| `notes` | string? | |
| `url` | string? | |
| `start`, `end` | ISO | all-day events: device-local midnights as instants, `allDay: true` |
| `allDay` | bool | |
| `availability` | `busy` \| `free` \| `tentative` \| `unavailable` | `notSupported` → `busy` |
| `status` | `confirmed` \| `tentative` \| `cancelled`? | |
| `attendees` | `[{name?, email?, status, organizer?}]`? | status: `accepted` `declined` `tentative` `pending` `unknown` |
| `attendeesCount` | int? | defaults to `attendees.length` |
| `organizer` | `{name?, email?}`? | |
| `travelTimeSec` | int? | not public in EventKit; send it when known (the apps store theirs with `PUT …/travel`) |
| `hasAlarms` | bool? | kept for older apps; `true` as well when `alarms` is not empty |
| `alarms` | `[{offsetSec} \| {at}]`? | at most 20: `offsetSec` = seconds from `start` (negative = before, EKAlarm `relativeOffset`), `at` = ISO instant (`absoluteDate`); location alarms (proximity) are not sent |

Rules, enforced by the gateway:

- Upsert by `(device calendar, externalId)`; sending the same batch twice changes nothing.
- `deleted` removes those occurrences. With `complete: true`, every event of that device calendar inside `window`
  that no batch of this `syncId` mentioned is removed (the window is clamped to [-30 d, +180 d] around now).
  Events outside the window older than 30 days are pruned.
- **Privacy `busy`**: only `start`, `end`, `allDay`, `availability`, `alarms` (and the ids) are stored; title,
  location, notes, url, attendees, organizer, travel time are discarded before writing. Alarm times reveal nothing
  about the event and let the apps notify « Occupé ». Switching a calendar to `busy` scrubs the stored
  rows at once; switching back to `full` sets `needsResync: true` on the calendar until the next `complete` sync.
- Disabled calendars (`enabled: false`) are not stored: their events are dropped on sync and deleted when disabled.
- `conferenceUrl` is derived server side from `url`, `location` and `notes` (Google Meet, Zoom, Teams, Webex,
  Whereby, Jitsi); never stored for busy-only calendars.
- Calendars unknown to `/sources` are rejected (`400`). Body limit 4 MB: batch by ~500 events.

Response `200`: `{ "upserted": 120, "deleted": 3, "removedStale": 1 }`.

### `POST /api/calendar/sync/events` (single event, for a snappy UI)

After you create/edit/delete an event in EventKit, the app mirrors it immediately:

```json
{ "calendarId": "6F1C…", "event": Event }        // upsert one occurrence (repeat for each changed occurrence)
{ "calendarId": "6F1C…", "deleted": ["<externalId>"] }
```

Response `200`: `{ "event": AgendaItem }` (the stored, privacy-filtered event) or `{ "deleted": n }`. The next full
sync remains the source of truth.

### Two devices

A calendar's identity across devices is its **key**: `lower(account) + " / " + lower(title)`. Calendars with the
same key are one calendar for the apps (`id` = stable hash of the key); its settings apply to every device's copy.
Events are served from the copy whose last `complete` sync is the most recent (`sources[].primary`), so the Mac and
the iPhone never show an event twice.

## Read API (apps)

### `GET /api/calendar/calendars`

```json
[ { "id": "k_3f9a1c2e7b",             // stable, from the key
    "key": "alex@example.com / travail",
    "title": "Travail", "account": "alex@example.com", "type": "caldav",
    "color": "#1BADF8",               // effective: override or device color
    "deviceColor": "#1BADF8", "colorOverride": null,
    "allowsModifications": true,
    "enabled": true, "privacy": "full", "countsForAvailability": true,
    "needsResync": false,
    "sources": [ { "deviceId": "…", "deviceName": "MacBook", "calendarIdentifier": "6F1C…",
                   "syncedAt": "…", "primary": true } ] } ]
```

### `PATCH /api/calendar/calendars/:id`

Body: any of `enabled` (bool), `privacy` (`"full"` | `"busy"`), `countsForAvailability` (bool), `colorOverride`
(`"#RRGGBB"` or `null`). Returns the calendar. Defaults for a new key: enabled, `full`, counts for availability.

### `GET /api/calendar/events?from=&to=&calendars=&reminders=&bookings=`

`from`/`to` ISO instants (or `YYYY-MM-DD`, Paris midnight), at most 400 days apart. `calendars` = comma list of
calendar ids (default: all enabled). `reminders=0` leaves reminders out. Sorted by `start`, overlapping the range.

```json
{ "from": "…", "to": "…", "items": [
  { "kind": "event", "id": "…", "calendarId": "k_3f9a1c2e7b", "externalId": "…", "seriesId": "…",
    "title": "Déjeuner Sami", "location": "Café Lomi", "coordinates": {"lat": 48.89, "lon": 2.35},
    "notes": "…", "url": "…", "conferenceUrl": "https://meet.google.com/abc-defg-hij",
    "start": "…", "end": "…", "allDay": false, "availability": "busy", "status": "confirmed",
    "attendees": [{"name": "Sami", "email": "…", "status": "accepted"}], "attendeesCount": 2,
    "organizer": {"name": "…", "email": "…"}, "travelTimeSec": 900, "travelMode": "driving", "hasAlarms": true,
    "alarms": [{"offsetSec": -900}, {"at": "…"}],
    "color": "#1BADF8", "busyOnly": false, "editable": true },
  { "kind": "event", "id": "…", "calendarId": "k_…", "title": null, "busyOnly": true,
    "start": "…", "end": "…", "allDay": false, "availability": "busy", "color": "#…",
    "hasAlarms": true, "alarms": [{"offsetSec": -600}] },
  { "kind": "reminder", "id": "<reminder id>", "title": "Payer l'URSSAF", "start": "<due_at>", "end": "<due_at>",
    "allDay": false, "done": false, "list": "inbox", "priority": 2 },
  { "kind": "booking", "id": "<booking id>", "title": "Rendez-vous 30 min · Jean Dupont", "start": "…", "end": "…",
    "bookingTypeId": "…", "status": "confirmed" }
] }
```

Busy-only events have `title: null` (the apps show « Occupé ») and none of the detail fields but their alarms.
`travelTimeSec` is the bridge's value or, when it has none, the one an app stored (`travelMode` then says how). Bookings are
listed only with `bookings=1` (`kind: "booking"`, `pending`/`confirmed` ones): once the bridge mirrors the Google
event they would show twice, so the default agenda relies on the mirror.

Extension tokens `widgets` and `watch` may call `GET /api/calendar/events` (read only).

### `PUT /api/calendar/events/:id/travel`

Travel time an app computed with MapKit for « Partir maintenant », from a place you chose (never the device's
position): `{ "travelTimeSec": 1500, "mode": "driving" }` (`driving` `transit` `walking` `cycling`, optional), or
`{ "travelTimeSec": null }` to clear it. `:id` is the agenda item id. Stored per calendar and `externalId`, so it
survives syncs and follows the event when another device's copy becomes the one served; dropped with the event,
when the calendar is disabled or switched to busy-only (`400` for a busy-only calendar). Response `200`
`{ "event": AgendaItem }`.

## Event notifications (apps)

The gateway sends no push for events: each app schedules local notifications from the merged agenda (so Mac-only
calendars notify on the iPhone too) for the next 48 h, and refreshes them on agenda changes, on foreground and in
the iPhone's background refresh (`<app bundle id>.calendar-sync`).

- **Alerts**: one notification per alarm (`alarms`, or the default alert of the app settings when an event has
  none), category `nuo.event` (`nuo.event.join` when there is a `conferenceUrl`: « Rejoindre »), actions
  « Ouvrir » and « Dans 5 min ». Title = event title, « Occupé » for busy-only calendars. Tap → `nuo://calendar/<id>`.
- **Partir maintenant**: timed events with a place that is not a visio link. MapKit ETA (with the departure time,
  for traffic) from the origin place of the settings (default « Maison ») or the event's own override, in the
  chosen mode; notification at `start − ETA − margin`, category `nuo.leave` (« Itinéraire » opens Plans). Skipped
  when origin and destination are within 300 m. The ETA is stored with `PUT …/travel`.
- Reminders and events share the 64 pending notifications iOS allows: soonest first, each kind keeps a minimum.

## Writing to Google (`gog`)

The gateway shells out to the `gog` CLI on the gateway host (already authenticated for the Google accounts). A Google target
is written `account/calendarId` (`alex@example.com/primary`); `account` alone means `primary`.

- `GET /api/calendar/google/calendars` → `[{target, account, id, title, primary, accessRole}]` for every account
  of `NUO_GOOGLE_ACCOUNTS` (for the UI pickers).
- `POST /api/calendar/events` → creates a Google event (invitations are emailed by Google):
  `{title, start, end, allDay?, location?, notes?, attendees?: ["a@b.c"], meet?: bool, target?: "account/calendarId"}`.
  `target` defaults to `NUO_GOOGLE_CALENDAR`. Response `201` `{googleEventId, target, htmlLink, meetUrl?}`.
  For all-day events `start`/`end` are `YYYY-MM-DD` (end exclusive). The event reaches the agenda with the next sync.
- Agents: `bun run src/cli.ts calendar-create --title … --start … --end … [--target …] [--attendee a@b.c]… [--meet]
  [--location …] [--notes …] [--all-day]` (same rules, prints the JSON result).

`gog` ≥ the version with `--send-updates` on `calendar update/delete` is needed for Google to email reschedules and
cancellations; with older versions (v0.9.0 and earlier) the event is changed/removed in Google (and in invitees'
Google calendars) but no email is sent. The gateway detects the flag once at start.

## Booking (Openings and Proposals)

### Booking type

```json
{ "id": "…", "slug": "rdv-30", "kind": "opening",       // opening | proposal
  "title": "Rendez-vous 30 min", "description": "…",
  "durationMin": 30,
  "location": { "kind": "google_meet" },                // google_meet | phone | address | custom; value for the last three
  "workingHours": { "mon": [["09:00","12:00"],["14:00","18:00"]], "tue": [...], "wed": [], "thu": [], "fri": [], "sat": [], "sun": [] },
  "bufferBeforeMin": 10, "bufferAfterMin": 10,
  "minNoticeMin": 240, "maxDaysAhead": 60, "maxPerDay": 4,      // maxPerDay null = unlimited
  "slotStepMin": 30,                                     // default = durationMin
  "googleCalendar": "alex@example.com/primary", // null = NUO_GOOGLE_CALENDAR
  "questions": [ { "id": "phone", "label": "Téléphone", "type": "phone", "required": false } ],   // text | longtext | phone | select (+ options)
  "candidateSlots": [ { "start": "…", "end": "…" } ],    // proposal only
  "active": true, "url": "https://rdv.example.com/rdv-30",
  "createdAt": "…", "updatedAt": "…" }
```

Name and email are always asked; `questions` add optional or required fields (at most 10). Slugs: `[a-z0-9-]{1,40}`,
unique. A **proposal** offers a fixed list of `candidateSlots` (still filtered by busy times and minimum notice)
and closes itself (`active: false`) after its first booking.

Device routes (`app` scope):

| route | |
|---|---|
| `GET /api/booking/types` | all types (archived ones with `?archived=1`) |
| `POST /api/booking/types` | create; `201` |
| `GET /api/booking/types/:id` | |
| `PATCH /api/booking/types/:id` | partial update |
| `DELETE /api/booking/types/:id` | archives (`204`); its bookings stay |
| `GET /api/booking/types/:id/slots?from&to` | free slots, as the public page sees them |
| `GET /api/booking/bookings?from&to&status&typeId` | bookings sorted by start, at most 500 (`status` = comma list or `all`; default: upcoming `confirmed`) |
| `GET /api/booking/bookings/:id` | |
| `POST /api/booking/bookings/:id/cancel` | cancels (Google event deleted); `{reason?}` |

Booking:

```json
{ "id": "…", "typeId": "…", "typeTitle": "…", "start": "…", "end": "…", "status": "confirmed",
  "invitee": { "name": "Jean Dupont", "email": "jean@…", "timezone": "Europe/Paris", "notes": "…", "answers": {"phone": "…"} },
  "googleEventId": "…", "googleTarget": "…/primary", "meetUrl": "…", "rescheduledFrom": null,
  "cancelReason": null, "createdAt": "…", "ip": "203.0.113.4" }
```

`status`: `pending` (Google event being created), `confirmed`, `cancelled`, `rescheduled` (replaced by a newer
booking whose `rescheduledFrom` points here), `failed` (Google refused; the slot is free again). Bookings are never
deleted.

### Availability

For each Paris day between `now + minNotice` and `now + maxDaysAhead` days: slots start at every `slotStepMin` from
each working-hours range start while `start + duration ≤ range end` (wall clock; DST-safe: a skipped time moves
forward, a repeated time is taken once). A slot is free when `[start − bufferBefore, end + bufferAfter]` overlaps
none of: events with `availability ≠ free` and `status ≠ cancelled` from enabled calendars with
`countsForAvailability`; `pending`/`confirmed` bookings of any type. Days already holding `maxPerDay` bookings of the
type are full. Booking creation re-checks inside a write transaction (`BEGIN IMMEDIATE`): two requests for the same
slot → one `201`, one `409`. Right before creating, the gateway also asks Google free/busy for the target calendar
(best effort) to catch events not yet bridged.

## Public booking host

Requests whose `Host` is in `NUO_BOOKING_HOSTS` (e.g. `rdv.example.com`) only ever reach these routes; every
other path is `404`, including all `/api/*` routes of the app. Requests on any other host never reach them. No
authentication; no request rate limiting (Turnstile + slot locking only).

| route | |
|---|---|
| `GET /` | `404` (no listing of booking types) |
| `GET /<slug>` | booking page (HTML, French, mobile first): month calendar, slots in the invitee's time zone with the Paris time alongside, form, confirmation with `.ics` download |
| `GET /api/public/booking/:slug/slots?from&to&tz` | `{timezone: "Europe/Paris", durationMin, slots: [{start, end}]}`; `from`/`to` = `YYYY-MM-DD` in `tz` (default Paris) or ISO, ≤ 62 days |
| `POST /api/public/booking/:slug` | `{start, name, email, notes?, answers?, timezone?, website: "", turnstileToken}` → `201 {booking: PublicBooking, manageUrl, icsUrl}`; `409` slot taken; `400` invalid; `403` Turnstile refused |
| `GET /m/:token` | manage page (details, cancel, reschedule) |
| `POST /m/:token` | `{action: "cancel", reason?}` or `{action: "reschedule", start, turnstileToken}` → `200 {booking, manageUrl, icsUrl}` |
| `GET /m/:token/slots?from&to&tz` | slots for rescheduling (its own booking does not block) |
| `GET /m/:token/event.ics` | calendar file of the booking |
| `GET /privacy`, `GET /terms` | privacy policy and terms (HTML, French); they come before the `/<slug>` route, so a booking type cannot shadow them |
| `GET /assets/booking.css`, `/assets/booking.js` | static assets |

`PublicBooking` = `{start, end, title, durationMin, location: {kind, value?}, meetUrl?, status, inviteeName}` —
never calendar names, event titles or other bookings. The manage token (32 random bytes, base64url) is stored hashed
(SHA-256); whoever has the link can cancel/reschedule.

Spam: Cloudflare Turnstile (`NUO_TURNSTILE_SITEKEY` / `NUO_TURNSTILE_SECRET`; if unset the gateway logs a
warning at start and skips the check — dev only), honeypot field `website` (must be empty; a filled one gets a fake
`201` and nothing is stored), strict validation (name ≤ 120, email syntax ≤ 254, notes ≤ 2000, answers per
question, start must be an offered slot), body ≤ 16 KB. Headers: strict CSP (`default-src 'none'`, scripts and
frames only from self and `challenges.cloudflare.com`, no inline script or style), `frame-ancestors 'none'`,
`nosniff`, `no-referrer`, HSTS.

`/privacy` and `/terms` are what Google requires before the OAuth app of `docs/protocol.md` (Google accounts) can
leave « Testing »; their text lives in `src/calendar/legal.ts` and names the operator (`NUO_BOOKING_OWNER`) and a
contact address (`NUO_LEGAL_CONTACT`; left empty, the pages carry no contact line).

A new booking pushes « 📅 Nouveau rendez-vous » (category `nuo.booking`, payload `bookingId`) to every paired
device; cancellations and reschedules by the invitee push « 📅 Rendez-vous annulé » / « 📅 Rendez-vous déplacé ».

## Storage (data.db, `006_calendar.sql`)

- `calendars(id, key UNIQUE, title, account, type, device_color, color_override, allows_modifications, enabled,
  privacy, counts_for_availability, needs_resync, created_at, updated_at)` — one row per key, holds the settings.
- `calendar_sources(id = deviceId:calendarIdentifier, calendar_id, device_id, device_name, calendar_identifier,
  title, color, account, type, allows_modifications, synced_at, created_at)`.
- `calendar_events(id, source_id, calendar_id, external_id, series_id, title, location, lat, lon, notes, url,
  conference_url, start_at, end_at, all_day, availability, status, attendees_json, attendees_count, organizer_json,
  travel_time_sec, has_alarms, alarms_json, sync_id, updated_at)`, unique `(source_id, external_id)`. A mirror: no
  history, rows are replaced and deleted freely.
- `calendar_event_travel(calendar_id, external_id, travel_time_sec, mode, updated_at)` (`009_calendar_alerts.sql`):
  travel times stored by the apps, pruned when their event is gone.
- `booking_types(…)` and `bookings(…)` as above (`manage_token_hash` unique). Bookings are never deleted.
- View `v_agenda(kind, id, calendar, title, location, start_at, end_at, all_day, busy_only, done)`: upcoming items
  from now − 1 day to + 180 days: events of the primary copy of enabled calendars (busy-only ones titled
  « Occupé », calendar name kept for the owner's agents) and open reminders with a due date. Bookings are in
  `bookings` (their Google event reaches `v_agenda` through the mirror).

## Environment

| variable | default | |
|---|---|---|
| `NUO_BOOKING_HOSTS` | (none: public pages off) | comma list of public hostnames |
| `NUO_BOOKING_BASE_URL` | `https://<first booking host>` | used in links and emails |
| `NUO_TURNSTILE_SITEKEY`, `NUO_TURNSTILE_SECRET` | (none: check disabled with a warning) | |
| `NUO_GOOGLE_CALENDAR` | (none) | default Google target `account[/calendarId]` |
| `NUO_GOOGLE_ACCOUNTS` | account of `NUO_GOOGLE_CALENDAR` | accounts listed by `/api/calendar/google/calendars` |
| `NUO_BOOKING_OWNER` | (none) | name shown on the public pages and in the `.ics` title |
| `NUO_BOOKING_UID_DOMAIN` | `nuo` | what follows `@` in the UID of the `.ics` files; an install renamed since its first bookings keeps the value its invitations had, or a guest who downloads one again gets it twice |
| `NUO_GOG_BIN` | `gog` | path of the gog binary; it needs `GOG_KEYRING_PASSWORD` in the gateway env when its keyring is file-based |
