# Task 04: Maneuvers (turn list for a planned route)

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md` section 7. Tasks 01 to 03b must be complete.

## Goal
Turn a `PlannedRoute` into a clean list of cue-sheet instructions a rider would actually want to hear. No live navigation yet; that is task 05.

## Steps

1. **`BikeNoCo/Routing/Maneuver.swift`:** `Maneuver` with type (depart, continue, slightLeft/Right, left/right, sharpLeft/Right, uTurn, arrive), coordinate, `distanceAlongRoute` (m), `distanceToNext` (m), `streetName` (String?), and `instruction` text.

2. **Name normalization (critical).** ArcGIS and OSM name the same street differently ("W LAUREL ST" vs "West Laurel Street"), and seams between ArcGIS edges, OSM edges, and synthetic attachments happen constantly. Without normalization the rider hears "Continue onto Laurel" every few blocks.
   - `NameNormalizer`: case-fold, expand/strip directionals (N/S/E/W), unify suffixes (St/Street, Ave/Avenue, Dr/Drive, Trl/Trail, Pkwy/Parkway), trim.
   - Use the normalized form only for comparisons; display the nicer original (prefer OSM-style title case over ArcGIS all-caps).
   - Unnamed edges inherit the previous named edge's name for comparison purposes while under 60 m; longer unnamed stretches display as "the path" (trail/cycleway/footway classes) or "the street".

3. **`BikeNoCo/Routing/ManeuverBuilder.swift`** per spec section 7:
   - First merge consecutive edges with the same normalized name into "runs". Synthetic attachment edges and edges under 20 m merge into the neighboring run.
   - Bearings measured 15 m before and after each run boundary, not at the raw vertex.
   - Emit a maneuver when the turn class is turn or sharper, or when the name changes with a slight turn or more. A name change while going straight emits a `continue` only if the new run is 150 m or longer (avoids chatter at seams).
   - Collapse maneuvers closer than 20 m.
   - Always emit depart and arrive.
   - Instruction text: "Turn left onto Mason Trail", "Bear right onto Spring Creek Trail", "Continue onto Remington St", "Arrive at destination".

4. **Tests** on synthetic routes:
   - 90-degree turn at a name change emits `left`/`right`.
   - "W LAUREL ST" (ArcGIS) to "West Laurel Street" (OSM) going straight emits nothing.
   - A 12 m synthetic attachment between two runs of the same trail emits nothing.
   - A short unnamed 30 m connector between two different named streets produces one maneuver, not two.
   - Zigzag jitter (small vertex wiggles under 15 m) does not produce turns.
   - Depart and arrive always present; distances sum to route length within 1 m.

5. **UI:** on the route summary card, add a "Turns" button that shows a sheet listing maneuvers (icon, instruction, distance to next in feet/miles). Tapping a row centers the map on that maneuver.

6. **DEBUG GPX export:** a DEBUG-only "Export GPX" action on the route card that writes the route as a GPX track (one point every ~5 m, timestamps at 12 mph) to the share sheet. This is what task 05 uses to test navigation with Xcode location simulation.

## Out of scope
Live navigation, voice, rerouting, one-way handling.

## Done when
- Build succeeds, all tests pass.
- Reply with the full maneuver list for each of the four sample routes (Old Town to CSU, Old Town to Spring Creek, CSU to City Park, Old Town to the former off-network point). Flag any maneuver that looks like seam chatter or a phantom turn.
