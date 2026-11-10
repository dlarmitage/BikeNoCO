# Task 05: Live turn-by-turn navigation

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md` sections 8 and 9. Tasks 01 to 04 must be complete and the cumulative-heading check must pass on the sample routes.

## Goal
Tap Start on a planned route and get spoken turn-by-turn guidance while riding, with the screen on or locked, including automatic reroute when the rider leaves the route. Navigation always records the ride.

## Steps

1. **Shared location source.** `RideRecorder` owns its own `CLLocationManager` today. Extract a `LocationProvider` (one `CLLocationManager`, background updates, `activityType = .fitness`, best accuracy while active) that publishes `CLLocation` updates. `RideRecorder` and the new `NavigationEngine` both consume it. Recording behavior, including auto-pause, must be unchanged; add or keep tests proving that.
   - Navigation keeps tracking while the recorder is auto-paused (stopped at a light).
   - `LocationProvider` accepts an injected location stream so tests and the DEBUG ride simulator (step 7) can drive it.

2. **`BikeNoCo/Routing/RouteProgressTracker.swift`** (pure Swift):
   - Match each fix to the route polyline, searching a window ahead of the last matched index (about 300 m), never the whole route, never backward more than 30 m.
   - Ignore fixes with `horizontalAccuracy` over 25 m for matching (still record them).
   - Output: distance along route, distance from route, remaining distance, current and next maneuver, distance to next maneuver.

3. **`BikeNoCo/Routing/NavigationEngine.swift`** (pure Swift state machine):
   - States: idle, navigating, offRoute, rerouting, arrived.
   - Prompt schedule per maneuver: "far" at about 150 m ("In 500 feet, turn left onto Mason Trail"), "near" at about 30 m ("Turn left"). Scale distances by 1.5x above 20 mph. Each prompt fires once; skip "far" if already inside it when the maneuver becomes next. Distances spoken in feet under 0.1 mi, else tenths of a mile.
   - Off-route: more than 30 m from the route for 5+ seconds with good accuracy, then reroute from the current location to the original destination using `RouteFinder`, off the main actor. Rate-limit to one reroute per 10 s. Announce "Rerouting" once. Rebuild maneuvers from the new route.
   - Arrival: within 20 m of the destination, announce "You have arrived", go to arrived. Recording continues until the rider stops it.
   - Emits events (prompt text, haptic kind, state change) rather than calling AVFoundation or UIKit directly, so it is fully testable.

4. **`BikeNoCo/Services/VoiceGuidance.swift`:** `AVSpeechSynthesizer` with audio session `.playback`, mode `.voicePrompt`, options `.duckOthers` and `.interruptSpokenAudioAndMixWithOthers`. Activate the session only while speaking and deactivate after, so music returns to full volume. Mute toggle persisted in `UserDefaults`.

5. **Haptics:** a distinct pattern for "far" vs "near" prompts and for off-route, via `UINotificationFeedbackGenerator` / `UIImpactFeedbackGenerator`.

6. **UI:**
   - Enable Start on the route card. Start begins recording and navigation together.
   - Navigation HUD (reuse `LiveRideHUD` patterns): maneuver icon, distance to next maneuver, upcoming street name, remaining distance, ETA at the rider's rolling average speed, mute button, End button.
   - Map follows the rider with heading-up while navigating.
   - Option (default on) to keep the screen awake while navigating in the foreground (`isIdleTimerDisabled`), restored on End.
   - Confirm `UIBackgroundModes` includes `location` and `audio` in `project.yml`, so prompts work with the screen locked.

7. **DEBUG ride simulator:** a DEBUG-only "Simulate Ride" action on the route card that feeds the route's GPX points into `LocationProvider` at 12 mph, with an option to inject a 100 m detour off the route halfway through (to exercise reroute). This is faster to iterate with than Xcode's GPX playback; keep the GPX export for Xcode-based testing too.

## Tests (pure Swift, synthetic routes)
- Progress matching follows a route with GPS noise of plus or minus 8 m without skipping maneuvers.
- A route that doubles back on itself (out and back on the same trail) does not jump ahead to the return leg.
- Each maneuver fires "far" then "near" exactly once; speed scaling moves trigger points.
- Low-accuracy fixes (35 m) do not trigger off-route.
- 6 s at 40 m off the route triggers exactly one reroute; a second departure within 10 s does not.
- Arrival fires once within 20 m.
- Recorder auto-pause behavior unchanged with the shared `LocationProvider`.

## Out of scope
Live Activities / lock screen widget, Apple Watch, CarPlay, loop planner.

## Done when
- Build succeeds, all tests pass.
- Simulate Ride on Old Town to CSU speaks every cue in order with correct timing (paste the console log of events with timestamps).
- Simulate Ride with the detour option triggers one reroute and rejoins guidance.
- With the simulator's screen locked, prompts still play.
