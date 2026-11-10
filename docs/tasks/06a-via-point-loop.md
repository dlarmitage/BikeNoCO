# Task 06a: Loop through a point (alternative to out & back)

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md`, the round-trip implementation (`PlannedRoute.isRoundTrip`, `asRoundTrip()`, `ManeuverBuilder.buildRoundTrip`). Task 05 and round trip must be complete.

## Goal
After long-pressing a destination, the rider picks how to get back: **One way**, **Out & back** (same path), or **Loop** (return by a different path). All three navigate with the existing engine.

## Steps

1. **Trip shape model.** Replace `isRoundTrip: Bool` with `enum TripShape { case oneWay, outAndBack, loop }` on `MapViewModel` and on `PlannedRoute`. Keep out & back behavior identical; migrate its tests.

2. **Multi-leg `PlannedRoute`.** Generalize the round-trip fields into `legs: [RouteLeg]` (each with edge range, distance, end coordinate, and an optional waypoint label). Out & back becomes two legs; loop becomes two legs. Stats cover the full trip. This is the structure 06b reuses with 3+ legs, so keep it general.

3. **Return-leg routing with reuse penalty.** In `RouteFinder`, add a variant that accepts an edge penalty map:
   - Outbound: normal A* origin to destination.
   - Return: A* destination to origin where every outbound edge costs x5, and any edge whose midpoint is within 40 m of outbound geometry costs x2 (prevents "different" routes that just use the parallel street or sidepath).
   - Penalties stay finite so a return is always found; when the network forces reuse (one bridge across the river), the route reuses it.
   - Keep the heuristic admissible (penalties only raise costs, so the existing heuristic remains valid).
   - Compute `overlapShare`: fraction of return-leg distance on outbound edges or within 40 m of outbound geometry.

4. **Maneuvers.** At the via point, emit a pass-through cue ("Passing your turnaround point at <street name>") instead of a U-turn. Normal turn cues apply where the return leaves the outbound path. Arrive at the origin.

5. **UI.** Segmented control on the route card: One way / Out & back / Loop. Switching shapes re-plans without a new long-press. Loop card shows total distance, low-stress %, and "X% different from the way out". If `overlapShare` is above 60%, show a short note: "Few alternate ways back here; much of the return repeats the outbound route."

## Tests (synthetic graphs)
- A square grid: loop return uses the opposite side of the square, overlap near 0%.
- A single bridge that must be crossed both ways: loop succeeds, overlap reflects the shared bridge only.
- The parallel-street case: a street 15 m beside the outbound trail is penalized so a genuinely different street 200 m away wins when it is not much longer.
- Out & back regression: identical results to before the refactor.
- Progress tracking on a loop whose start and end share a 300 m "stem" (lollipop shape) does not jump ahead.

## Done when
- Build succeeds, all tests pass.
- Simulate Ride on a loop speaks the pass-through cue and arrives at the origin.
- Reply with three real loops (Old Town to CSU, Old Town to Spring Creek, one of your choice): distance out, distance back, overlap %, low-stress %.
