# Task 07: Ride log and saved routes

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md`, `Models/RideSession.swift`, `Services/RideRecorder.swift`, `Views/RideSummaryView.swift`, `RouteFinder.routeThrough`. Tasks through 06b must be complete and committed.

## Goal
1. Every recorded ride is kept automatically, so the rider can see performance over time.
2. From the ride summary, the rider can star a ride ("Add to My Routes"); it becomes a named, navigable route.
3. Rides on the same saved route are compared against each other.

Today a finished `RideSession` is shown in `RideSummaryView` and then discarded. Nothing is persisted.

## Steps

1. **Persistence with SwiftData** (Apple framework, iOS 17; no packages). New `BikeNoCo/Persistence/`:
   - `SavedRide` (`@Model`): id, start/end dates, all `RideSession` stats, moving duration, optional name, optional relationship to `SavedRoute`, `wasNavigated` flag, and the track stored as compact `Data` (delta-encoded coordinates at 1e-6 degrees plus altitude, speed, timestamp offsets, lzfse-compressed). Keep `RideSession` as the in-memory type; add conversions both ways.
   - `SavedRoute` (`@Model`): id, name, created date, routing waypoints (`[coordinate]`), cached total distance, low-stress share, optional notes, source ride id, inverse relationship `rides`.
   - A `ModelContainer` set up in `BikeNoCoApp`. Tests use an in-memory container.

2. **Auto-save.** When recording finishes, save the ride automatically. Exception: rides under 0.1 mi or 2 minutes of moving time are not auto-saved (accidental taps); the summary shows a "Save this ride" button instead. The summary also gets a "Delete ride" action (with confirmation) for rides the rider doesn't want kept.

3. **Better elevation.** GPS altitude with a 2 m threshold overstates climbing. During recording, also run `CMAltimeter` relative altitude when available and use it for elevation gain/loss, falling back to GPS. Add `NSMotionUsageDescription` via `project.yml`/Info.plist.

4. **Rider weight setting.** Calories currently assume 70 kg. Add a rider weight setting (lb, default 154) in an existing settings or filter sheet and use it in the calorie estimate. Update the summary footnote.

5. **Add to My Routes (star on the summary):**
   - Prompt for a name, prefilled from the ride's dominant named runs (reuse the loop-planner naming logic: "Spring Creek and Poudre Trail Loop").
   - Convert the GPS track into routing waypoints: sample about every 400 m plus at sharp heading changes (more than 45 degrees over 30 m smoothed), then `RouteFinder.routeThrough`. Compare the routed geometry to the track; where they diverge by more than 40 m for more than 150 m, insert extra waypoints from the track there and re-route. At most 3 refinement passes. Store the final waypoints, not the raw track, on the `SavedRoute`.
   - Report the match quality (share of routed distance within 30 m of the track) in DEBUG logs. Target 90%+.
   - Link the source ride to the new route.

6. **Linking future rides to routes.**
   - Rides started by navigating a saved route link to it automatically.
   - Freely recorded rides auto-link to an existing saved route when 80%+ of the track is within 30 m of the route and distance is within 10%. Otherwise unlinked.

7. **UI: a "Rides" entry point** on the map (toolbar button) opening a sheet with two tabs:
   - **My Rides:** list grouped by month; header with this week / month / year totals (distance, moving time, elevation); a weekly distance bar chart (Swift Charts) for the last 12 weeks. Tap a ride to open the existing summary view with stored data. Swipe to delete with confirmation. DEBUG: export GPX via the existing exporter.
   - **My Routes:** list with name, distance, times ridden, best time. Tap for detail: map preview, **Ride this route** (opens it as the planned route and goes through the existing Start flow), rename, delete (confirm; rides are kept and unlinked). History section: a chart of moving time and average speed for each ride on this route, best highlighted.
   - Ride summary: when a ride links to a route, show "3rd time on Spring Creek Loop", plus a "Personal best" badge if it is the fastest moving time on that route.

## Tests
- `SavedRide` round-trip through an in-memory container, including track encoding within 0.2 m and 1 s.
- Short ride (under 0.1 mi or 2 min) is not auto-saved.
- Track-to-route conversion on a synthetic graph reproduces a zigzag track with 90%+ match.
- Auto-linking: a ride matching a saved route links; a ride sharing only half of it does not.
- Personal best detection across three rides on one route.
- Deleting a route keeps its rides.

## Out of scope
iCloud sync, Apple Health export, sharing routes with others, editing a route by dragging. (Health export is a good small follow-up task.)

## Done when
- Build succeeds, all tests pass.
- Using Simulate Ride: record the Old Town to CSU route; it appears in My Rides. Star it; it appears in My Routes with match quality reported. Choose Ride this route and simulate again; the summary shows "2nd time" and the route history chart shows two rides.
- Reply with the match quality for that route and screenshots or descriptions of the two tabs.
