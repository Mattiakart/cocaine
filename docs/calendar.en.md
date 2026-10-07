# The island's Calendar page

Three views, switched with the segmented control in the page's header (Day · Week · Month). The header also holds the title
of what is shown, the previous/next buttons and *Today*.

- **Day**: the big date on the left and that day's events; an empty today lists the next two weeks instead ("Coming up").
- **Week**: seven columns starting on the Mac's first weekday (System Settings → General → Language & Region), each with its
  events as compact chips in the calendar's colour; all-day events are tinted. Today's column is outlined in the accent.
  Clicking a day's header opens that day.
- **Month**: the grid (weekday names in the app's language, days of other months dimmed, today in the accent, up to three dots
  per day in the calendars' colours and "+n" for more) and, beside it, the selected day's events. Click a day to select it,
  click it again (or press Return) to open it in the Day view. Regions that use week numbers (Germany, the Nordic countries,
  the Netherlands…) get a week-number column and "Week 41" in the Week view's title.

Click an event for its details: date and time (or *All day*, with the dates when it spans days), the calendar, the place,
the organiser and number of attendees, the start of the notes, a video-call link (Zoom, Meet, Teams, Webex…, only http(s)
links: it opens in your browser) and **Open in Calendar**. Back (or Esc) returns to the view.

**Open in Calendar** uses Calendar's own `ical://ekevent/<id>?method=show&options=more` link, which needs no permission.
Opening Calendar *at a date* without an event would need AppleScript and the Automation permission, so it isn't done.

## Keys

With the island opened from the keyboard (⌃⌥⌘I) and the Calendar page shown:

| Key | Day | Week | Month |
|---|---|---|---|
| ← / → | previous / next day | previous / next week | previous / next day (across months) |
| ↑ / ↓ | — | — | a week back / forward |
| Page Up / Page Down | previous / next day | previous / next week | previous / next month |
| Home or T | today | today | today |
| Return | — | — | open the selected day |
| Esc | closes the details, otherwise the island | | |

While the Calendar page is shown, ← and → belong to it (on the other pages they change tabs). Tab moves between the page's
controls with Full Keyboard Access.

## Data

- Events are read with EventKit (full access), off the main thread, for the shown range: the week for Day and Week, the
  month's whole grid for Month. Each range is cached (12 ranges at most) and the ranges either side are prefetched, so the
  next tap draws at once. A change in your calendars (`EKEventStoreChanged`), a new day, a time-zone or region change empties
  the cache and reads again.
- Recurring events come from EventKit already expanded, one per occurrence.
- An event is on every day it covers: an all-day event of three days is on three days; a timed event ending exactly at
  midnight isn't on the next day; an evening past midnight is on both. Days are counted on the wall clock, so DST days
  (23 or 25 hours) and time-zone changes put events on the right day.
- **Declined events** are shown dimmed and struck through, with "Declined", and are not counted (no dot, not in "3 events"):
  they don't take your time, but you can still see them.
- Access: not asked yet → *Allow Calendar*; refused (or write-only) → where to allow it and *Open Settings*.

## Motion and accessibility

Changing range slides the content in from the side it comes from; changing view zooms from the selected day; selecting a day
moves one highlight; *Today* pulses the today mark. Every animation is driven by one state (the view and the selected day):
quick repeated taps restart the arrival from the jump and always end on the right range, never half-way. With Reduce Motion
the content only fades in.

VoiceOver: each grid day is a button labelled like "Tuesday 7 October, 3 events" (with "Today" when it is), selected days have
the selected trait; view and range changes are announced ("Month view, October 2026").

## Tests and renders

- `Cocaine --calendar-test`: month grids for every month of 2026–2028 with Monday, Sunday and Saturday first, months starting
  on each weekday, 4- and 6-week months, February 2028, DST in Rome (March and October 2026), multi-day and all-day events,
  time zones, the navigation reducer and its clamping (±10 years), the keys, video links, notes, the cache and prefetch with
  a background source, invalidation.
- `Cocaine --render-island out.png --open --tab calendar --calendar-view day|week|month [--calendar-details]
  [--calendar-select 2026-03-15] [--calendar-access denied|notasked] [--notch-height 38] --lang it`: draws the page with
  sample events (renders never read your calendar).
