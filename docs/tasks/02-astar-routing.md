# Task 02: Point-to-point routing with map preview

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md` sections 5 and 9. Task 01 must be complete.

## Goal
Long-press anywhere on the map, get a low-stress bike route from the current location to that point, and see it drawn with a summary card.

## Steps

1. **`BikeNoCo/Routing/RoutingProfile.swift`:** facility multipliers, LTS modifier, optional `maxLTS`, `avoidNaturalSurface` flag, `maxSnapMeters = 150`. Defaults from the spec table. A `cost(for: GraphEdge) -> Double?` that returns nil for disallowed edges.

2. **`BikeNoCo/Routing/RouteFinder.swift`:**
   - Snap origin and destination onto the nearest edge within `maxSnapMeters`, inserting temporary virtual nodes (do not mutate the shared graph; use an overlay).
   - A* with a binary-heap priority queue (write it; no packages) and the admissible heuristic from the spec.
   - Return `Result<PlannedRoute, RoutingError>`. Errors: `originTooFar`, `destinationTooFar`, `noPath` (with a hint when origin and destination are in different components).

3. **`BikeNoCo/Routing/PlannedRoute.swift`:** edge sequence, coordinates (including the partial edges at each end), total distance, meters per `FacilityType`, low-stress share (LTS <= 2 or any trail), dominant names.

4. **Tests** on synthetic graphs:
   - Prefers a 1.2 km trail over a 1.0 km sharrow path (with default multipliers).
   - `maxLTS = 2` avoids an LTS 4 shortcut; returns `noPath` if that is the only way.
   - Snapping to the middle of an edge produces correct partial distances.
   - Origin/destination beyond 150 m returns the right error.
   - Different components return `noPath`.

5. **UI:**
   - `MapViewModel`: `@Published var plannedRoute: PlannedRoute?`, `routingError`, and a `planRoute(to:)` that runs off the main actor.
   - `BikeMapView`: long-press gesture sets the destination and calls `planRoute`. Draw `plannedRoute` as its own overlay style (thick, distinct from facility colors and from recommended rides) plus a destination pin.
   - Bottom card: distance (mi), low-stress %, main names, and Clear. A Start button can be present but disabled ("Navigation coming soon").
   - Friendly error text for each `RoutingError`.

## Out of scope
OSM connectors, turn-by-turn, voice, rerouting, loop planning.

## Done when
- Build succeeds, all tests pass.
- In the simulator (location set to Fort Collins, for example Old Town near College and Mountain), long-pressing near CSU or on the Spring Creek Trail shows a sensible route in under 1 second.
- Reply with: 3 example routes you tried, their distances and low-stress %, and any failures caused by network gaps (these feed task 03).
