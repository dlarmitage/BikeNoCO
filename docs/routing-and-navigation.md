# Routing and Turn-by-Turn Navigation

**Status:** Approved direction, building in phases
**Last updated:** 2026-11-09 (phase 1 results folded in)
**Relationship to other docs:** Extends `docs/smart-route-planner.md` (June 2026). That doc's graph design and loop planner remain valid. This doc adds point-to-point routing and turn-by-turn navigation, which the June doc listed as non-goals, and supersedes it wherever they conflict.

---

## 1. Goals

1. **Plan a route** from the rider's location (or any point) to a destination, preferring low-stress infrastructure.
2. **Turn-by-turn navigation** while riding: voice prompts, haptics, off-route detection, automatic reroute.
3. **Loop planning** (from the June doc) on the same graph.
4. Everything runs **on device, offline once data is loaded, with no third-party dependencies**.

Non-goals for now: routing outside Fort Collins/Loveland, live traffic, elevation-aware routing (elevation is display-only until a later phase), CarPlay, Apple Watch.

## 2. Key constraint: the network has gaps

The ArcGIS layers contain bike facilities and trails, not the full street grid. Consequences:

- Origins and destinations (a house, a coffee shop) are often off the network.
- City data has small gaps between segments that should connect.
- Trails that cross streets on bridges or underpasses must NOT be connected where they cross.

Strategy:
- Phase 1 measures connectivity and lists gaps.
- Phase 3 adds a bundled, preprocessed OpenStreetMap street layer for NoCo as **connector edges** with a high cost multiplier, so the router uses streets only to reach or bridge the bike network.

## 3. Architecture

```
ArcGISService ──> [BikeRoute] ──┐
                                ├──> BikeNetworkGraphBuilder ──> BikeNetworkGraph
Bundled OSM connectors (Ph 3) ──┘                                    │
                                                                     ▼
                                   RoutingProfile ──> RouteFinder (A*) ──> PlannedRoute
                                                                     │
                                                                     ▼
                                                     ManeuverBuilder ──> [Maneuver]
                                                                     │
                       LocationProvider ──> NavigationEngine <───────┘
                                                 │
                                   VoiceGuidance / Haptics / NavigationHUD
```

All of `BikeNoCo/Routing/` is pure Swift (Foundation + CoreLocation). Views and view models consume it.

## 4. Graph (Phase 1)

- **Projection:** convert lat/lon to local planar meters (equirectangular around ~40.5 N). Accurate to well under 1% across the service area and much faster than haversine in hot loops.
- **Spatial index:** uniform grid hash (about 25 m cells). No R-tree library.
- **Nodes:**
  - Path endpoints clustered within `endpointSnapMeters` (default 12 m, raised from 8 m after the phase 1 report showed many 8 to 10.5 m endpoint gaps).
  - **T-junctions:** an endpoint within `tJunctionSnapMeters` (default 8 m, kept tight) of another polyline's interior splits that polyline and joins there. Kept separate from endpoint snap because parallel geometry (both sides of a street, trail beside street) sits 8 to 10 m apart and must not be stitched together along its length.
  - **X-crossings without shared vertices are NOT joined** (likely grade-separated). Count and report them.
- **Edges:** one per polyline piece between nodes. Store: from/to node ids, length, geometry, `facilityType`, `lts`, `name` (bikewayName, else streetName), source route id, `isConnector` flag.
- **Direction:** bidirectional for v1. One-way handling is a later refinement.
- **Exclude** `.recommendedRide` routes.
- **Connectivity report:** node/edge counts, number of components, largest component share of total edge length, crossing count, and a list of gap candidates (dangling endpoints within 25 m of a different component).

## 5. Routing (Phase 2)

- **A\*** over the graph with cost = edge length x multiplier.
- **Default multipliers** (tunable in `RoutingProfile`):

| Facility | Multiplier |
|---|---|
| Paved Multiuse Trail | 0.8 |
| Separated Bike Lane | 0.85 |
| Buffered Bike Lane | 0.95 |
| Bike Lane, Sidepath | 1.0 |
| Advisory Bike Lane | 1.1 |
| Sharrow | 1.4 |
| Natural Surface Trail | 1.5 (profile option to avoid) |
| Unclassified | 1.5 |
| No Bike Facilities | 2.0 |
| OSM connector (Phase 3) | 2.5 |

- **LTS modifier:** LTS 3 x1.5, LTS 4 x3.0, nil = no modifier. Optional hard cap `maxLTS` removes edges above it.
- **Heuristic:** straight-line distance x the smallest multiplier in the profile, so it stays admissible.
- **Snapping:** project origin and destination onto the nearest edge (not just node) within `maxSnapMeters` (default 150 m) and insert temporary virtual nodes. If either fails, return a clear error instead of a bad route.
- **Output `PlannedRoute`:** ordered edge list, full coordinate list, total distance, distance per facility type, share of low-stress mileage, and a dominant-name summary.
- **Low-stress mileage** (honest mixed ArcGIS + OSM definition):
  - **Counts as low-stress:** paved/natural trail; ArcGIS with LTS ≤ 2; OSM `cycleway` / `path` / `track`; OSM `footway` / `pedestrian` (bike-allowed connectors); OSM `residential` / `living_street`; synthetic attachment edges.
  - **Not low-stress:** OSM `service` / `unclassified`; OSM tertiary and above; ArcGIS LTS 3+; ArcGIS sharrow / no-facility / other with nil LTS.

## 6. OSM connectors (Phase 3)

- A small dependency-free script (`tools/build_osm_connectors.py`, Python stdlib only) pulls OSM `highway=*` ways for the NoCo bounding box from Overpass, drops motorways/trunks and ways tagged `bicycle=no`, simplifies geometry, quantizes coordinates, and writes a compact bundled resource.
- Connector edges are merged into the graph with `isConnector = true` and a per-OSM-class multiplier (see task 03), after conflation drops OSM ways that duplicate ArcGIS geometry.
- OSM also resolves the ArcGIS X-crossings: an at-grade OSM intersection near the crossing joins it; bridge/tunnel ways keep it separated.
- ODbL requires "© OpenStreetMap contributors" attribution in the app.
- Re-run the script occasionally; the output is committed to the repo.

## 7. Maneuvers (Phase 4)

Built from the edge sequence of a `PlannedRoute`:
- Compute bearing in/out at each node using geometry about 15 m either side of the node (avoids GIS jitter).
- Turn angle classes: straight (< 25 degrees), slight (25 to 60), turn (60 to 135), sharp (> 135), U-turn.
- Emit a maneuver when the turn is "turn" or sharper, OR when the name changes with a "slight" turn or more. Pure name changes while going straight merge silently ("Continue on Spring Creek Trail").
- Collapse maneuvers closer than 20 m into one.
- Each maneuver: coordinate, distance along route, type, direction, upcoming name, instruction text ("Turn left onto Mason Trail").
- Always include depart and arrive maneuvers.

## 8. Navigation engine (Phase 5)

- **Location source:** `RideRecorder` owns its own `CLLocationManager` today. Refactor so a shared `LocationProvider` publishes `CLLocation` updates that both the recorder and the navigation engine consume. Navigation always records the ride.
- **Progress:** match each fix to the route polyline (search a window ahead of the last matched index, not the whole route). Track distance along route, distance to next maneuver, remaining distance.
- **Prompts:** announce at about 150 m ("In 500 feet, turn left onto Mason Trail"), at about 30 m ("Turn left"), plus a haptic on each. Scale distances up with speed above 20 mph.
- **Off-route:** more than 30 m from the route for 5 or more seconds with reasonable accuracy (horizontalAccuracy < 25 m) triggers reroute from the current position to the original destination. Rate-limit reroutes to one per 10 s.
- **Arrival:** within 20 m of the destination, announce arrival and stop guidance (recording continues until the rider stops it).
- **Voice:** `AVSpeechSynthesizer` with an audio session category of `.playback` and `.duckOthers` so music or podcasts dip during prompts. Respect a mute toggle.
- **Background:** existing `location` background mode covers it. Prompts must work with the screen locked.

## 9. UI

- Long-press the map to set a destination; origin defaults to current location.
- Route preview: distinct polyline style (`plannedRoute` overlay, separate from `activeRouteID` recommended rides), summary card with distance, low-stress %, and a Start button.
- Navigation HUD: next maneuver icon and distance, street name, remaining distance and ETA; reuses `LiveRideHUD` patterns.
- Optional DEBUG-only overlay that colors graph components and marks gap candidates.

## 10. Testing

- Unit tests (`BikeNoCoTests` target) for graph building, snapping, A*, maneuver generation, and the navigation engine, all against small synthetic graphs.
- Navigation tested at the desk: export a planned route to GPX and replay it with Xcode location simulation. Add a DEBUG "Export GPX" action for this.
- Field test: ride 10 planned routes; log reroutes, missed prompts, and bad maneuvers.

## 11. Phases

| Phase | Task file | Outcome |
|---|---|---|
| 1 | `tasks/01-graph-spike.md` | Test target, graph builder, connectivity report |
| 2 | `tasks/02-astar-routing.md` | Point-to-point routing with preview on the map |
| 3 | `tasks/03-osm-connectors.md` | Routes start and end anywhere in NoCo |
| 3b | `tasks/03b-osm-tuning.md` | Fast cached graph build, pruned islands, honest low-stress metric |
| 4 | `tasks/04-maneuvers.md` | Turn list for a planned route |
| 5 | `tasks/05-navigation-engine.md` (to write) | Live turn-by-turn with voice and reroute |
| 6 | `tasks/06-loop-planner.md` (to write) | Loop planner from the June doc |

Task files for phases 3 to 6 get written after phase 1's connectivity numbers are known, since those numbers shape phase 3.
