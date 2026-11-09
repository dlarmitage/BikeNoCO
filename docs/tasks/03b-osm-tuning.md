# Task 03b: OSM merge tuning (performance, pruning, low-stress metric)

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md`. Task 03 must be complete.

## Context from task 03 results
- Graph build went from 0.69 s to 10.90 s on the simulator. A real iPhone will be slower. Unacceptable at launch.
- Components went from 61 to 984: isolated OSM stubs. A destination can snap onto one and return `noPath` despite a connected street nearby.
- Low-stress share dropped on every route (CSU to City Park: 97% to 30%, while distance fell 1.63 to 0.74 mi). Likely partly because `isLowStress` treats all connector edges as stressful, including residential streets and OSM cycleways.

## Steps

1. **Diagnose first.** For the four sample routes, print a per-edge breakdown: source (ArcGIS facility type or OSM class), name, length. Include it in your reply. Do not change multipliers in this task.

2. **Stage timing.** Instrument the build: OSM decode, conflation, attachment, crossing resolution, component computation, everything else. Report the table before optimizing. Then fix the hot spots (use `SpatialGrid` everywhere; sample OSM geometry at about 5 m intervals for conflation instead of exact segment-to-segment tests; avoid repeated array copies). **Target: under 2 s on the simulator for a full rebuild.**

3. **Prune.** After merging, drop every connected component that contains no ArcGIS edge. Report the component count and largest share after pruning.

4. **Low-stress definition.** Update `RoutingProfile.isLowStress` and document the rule in the spec section 5:
   - Low-stress: paved/natural trail, ArcGIS LTS <= 2, OSM cycleway/path/track, OSM footway/pedestrian (bike-allowed), OSM residential/living_street, synthetic attachment edges.
   - Not low-stress: OSM service/unclassified, tertiary and above, ArcGIS LTS 3+, ArcGIS sharrow/no-facility with nil LTS.

5. **Graph cache.** Serialize the finished, pruned graph (Codable to a compact binary or JSON file in Application Support).
   - Cache key: hash of the sorted ArcGIS `(source layer, objectId, point count)` tuples plus the OSM file's `meta` timestamp. **Do not use `BikeRoute.id`; it is a fresh UUID every fetch.** Store objectIds on edges (or a remap table) so cached edges still resolve names and facility data.
   - On launch: load the cached graph if present (target < 0.5 s), make routing available immediately, then verify the key against freshly fetched ArcGIS data in the background and rebuild only if it changed.
   - Routing UI shows a small "Preparing routes..." state only when there is no usable cache.

6. **Tests:** pruning removes an OSM-only island and keeps an island containing ArcGIS edges; cache round-trip yields identical route results on a synthetic graph; cache key is stable across two fetches with new UUIDs; the new `isLowStress` rules.

## Done when
- Build succeeds, all tests pass.
- Reply with: the stage timing table before and after, cold build time, cached load time, component count after pruning, and the four sample routes with distance, low-stress %, connector %, and the per-edge class breakdown for CSU to City Park.
