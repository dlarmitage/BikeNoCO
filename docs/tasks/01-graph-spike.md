# Task 01: Test target, graph builder, connectivity report

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md` sections 2, 3, 4, 10.

## Goal
Turn the existing `[BikeRoute]` into a routable graph and measure how connected it is. No routing yet.

## Steps

1. **Add a unit test target** `BikeNoCoTests` in `project.yml` (type `bundle.unit-test`, iOS, host app BikeNoCo) and include it in the BikeNoCo scheme's test action. Run `xcodegen generate`. Add one trivial passing test and confirm `xcodebuild ... test` works before going further.

2. **Create `BikeNoCo/Routing/`** with:
   - `LocalProjection.swift`: lat/lon to planar meters and back (equirectangular, reference latitude passed in). Plus point-to-segment projection helpers.
   - `SpatialGrid.swift`: generic uniform grid hash for points and segments; query by radius.
   - `BikeNetworkGraph.swift`: `GraphNode`, `GraphEdge` (fields per spec section 4), adjacency list, lookup by id.
   - `BikeNetworkGraphBuilder.swift`: builds the graph from `[BikeRoute]` per spec section 4 (endpoint clustering, T-junction splitting, no joining at X-crossings, exclude `.recommendedRide`). Config struct with `endpointSnapMeters = 8`, `gapSearchMeters = 25`.
   - `ConnectivityReport.swift`: components via union-find or BFS; report node count, edge count, component count, largest component share of total edge length, X-crossing count, and gap candidates (dangling endpoint, other component within 25 m: both coordinates plus distance).

3. **Unit tests** with synthetic routes (build tiny `BikeRoute` values in code):
   - Two segments whose endpoints are 5 m apart join into one component; 15 m apart stay separate and appear as a gap candidate.
   - A segment ending 4 m from the middle of another splits it (T-junction): 3 edges, 1 component.
   - Two segments that cross in an X with no shared vertex stay separate components and count as 1 crossing.
   - `.recommendedRide` routes are excluded.
   - Edge lengths within 1% of a hand-computed value.

4. **Wire it in, DEBUG only:** after `MapViewModel.loadRoutes()` finishes, build the graph on a background task and print the connectivity report to the console (top 20 gap candidates by distance). Time the build and print it. No UI changes beyond that.

## Out of scope
Routing, OSM data, UI overlays, persistence/caching, one-way streets.

## Done when
- Build succeeds, all tests pass.
- Running the app in the simulator prints the connectivity report and the build time.
- Reply with: the report numbers from a real run, the build time, and anything surprising in the data (for example, duplicate geometry between FC and Loveland layers).
