# Task 03: OSM connector layer

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md` sections 2, 4, 5, 6. Tasks 01 and 02 must be complete.

## Why
Phase 1/2 results: largest component holds 83.7% of mileage across 61 components; 71 unjoined X-crossings; destinations like (40.57900, -105.09800) fail with `destinationTooFar`. OSM streets fix all three: reach off-network points, bridge islands, and tell us which crossings are at-grade.

## Part A: build script (runs on the Mac, output committed)

Create `tools/build_osm_connectors.py`, **Python 3 standard library only** (urllib, json, math). It:

1. Queries Overpass (`https://overpass-api.de/api/interpreter`) for ways in bbox **south 40.33, west -105.20, north 40.68, east -104.95** with `out geom` plus node ids (use `out body; >; out skel qt;` or equivalent so shared node ids are available for topology).
2. Keeps `highway` in: residential, living_street, unclassified, service (drop `service=parking_aisle|driveway|drive-through`), tertiary(+_link), secondary(+_link), primary(+_link), cycleway, path, track, and footway/pedestrian only when `bicycle=yes|designated`.
3. Drops: motorway, trunk (+links), construction, proposed, steps, `bicycle=no|dismount`, `access=private|no` (unless `bicycle=yes`).
4. Splits ways at nodes shared by 2+ kept ways (native OSM topology).
5. Writes `BikeNoCo/Resources/osm_connectors.json`:
   - `meta`: source, OSM timestamp from the Overpass response, bbox, attribution `© OpenStreetMap contributors (ODbL)`.
   - `edges`: `[{ "h": highway class, "n": name or null, "b": 1 if bridge, "t": 1 if tunnel, "a": startNodeId, "z": endNodeId, "c": [delta-encoded ints at 1e-5 degrees, lat/lon interleaved] }]`.
   - Simplify geometry (Douglas-Peucker, 3 m tolerance) but never drop a node id used at a split.
6. Prints edge count, file size, and highway class breakdown. **Target file size under 5 MB.** If over, report it and stop; don't silently drop classes.

Add `osm_connectors.json` to the app bundle via `project.yml`.

## Part B: merging into the graph

New `BikeNoCo/Routing/OSMConnectorLoader.swift` (decode + delta-decode) and extend `BikeNetworkGraphBuilder` with an optional connectors input:

1. **Conflation (avoid duplicates):** drop any OSM edge where 80%+ of its length lies within 10 m of an ArcGIS edge. Duplicated streets/trails would otherwise cause zig-zag routing and junk maneuvers later.
2. **Attachment:** connect each ArcGIS graph node to the nearest OSM node within 15 m with a short synthetic connector edge, **skipping OSM nodes that only touch bridge or tunnel ways**. Also allow OSM-node-to-ArcGIS-edge-interior T-attachment within 8 m (same rule as ArcGIS T-junctions).
3. **At-grade crossing resolution:** for each ArcGIS X-crossing, if an OSM node of degree 3+ with no bridge/tunnel ways sits within 10 m of the crossing point, split both ArcGIS edges there and join them. Otherwise leave it separated. Report how many of the 71 crossings got joined.
4. **Costs:** connector edges get a multiplier by OSM class instead of the single `connectorMultiplier`:

| OSM class | Multiplier |
|---|---|
| cycleway, path, track (bike-allowed) | 1.2 |
| footway/pedestrian (bicycle=yes/designated) | 1.4 |
| residential, living_street | 2.0 |
| unclassified, service | 2.2 |
| tertiary | 3.0 |
| secondary | 4.0 |
| primary | 6.0 |
| synthetic attachment edges | 1.0 |

   Keep `minimumMultiplier` correct so A* stays admissible.
5. `GraphEdge` gets an `osmClass` (nil for ArcGIS edges). `isConnector` stays true for all OSM and synthetic edges.
6. `PlannedRoute` adds `connectorShare` (fraction of distance on connector edges) for the summary card.
7. Lower `maxSnapMeters` stays 150 for now.

## Part C: attribution
ODbL requires attribution. Add "© OpenStreetMap contributors" to the existing data sources / about area in the UI (wherever ArcGIS and RideWithGPS sources are credited, or a small info sheet if none exists).

## Tests (synthetic, no bundled file)
- OSM edge running 6 m alongside an ArcGIS edge for its full length is conflated away; one 30 m away is kept.
- ArcGIS node 10 m from an OSM node gets attached; 20 m does not.
- Attachment skips an OSM node that only touches a bridge way.
- X-crossing with a degree-3 at-grade OSM node nearby gets joined; with a bridge way there, it does not.
- Router uses a residential connector to reach an otherwise unreachable ArcGIS island, and prefers a slightly longer trail over a primary road connector.
- Delta decoding round-trips coordinates within 1.5 m.

## Out of scope
Turn-by-turn, one-way handling, elevation, removing ArcGIS/ArcGIS parallel duplicates.

## Done when
- Script runs and produces a file under 5 MB; file is in the bundle.
- Build succeeds, all tests pass.
- DEBUG connectivity report re-run. Reply with a before/after table: components, largest component %, crossings joined, total graph build time (now including OSM load).
- (40.57900, -105.09800) now routes from Old Town.
- Re-run the three task 02 routes and report distance, low-stress %, and connector share for each. Low-stress % should not drop meaningfully; if it does, the conflation or multipliers need tuning, so say so rather than tweaking silently.
