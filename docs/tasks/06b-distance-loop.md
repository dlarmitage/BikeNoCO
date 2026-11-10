# Task 06b: Distance loop planner ("15 miles from here")

Read first: `.cursor/rules/bikenoco.mdc`, `docs/routing-and-navigation.md`, `docs/smart-route-planner.md` (the June design: goals, UX, constraints model). Task 06a must be complete. Where the June doc and this task differ, this task wins: the graph, routing, and navigation it lists as future work now exist.

## Goal
From the rider's location (or a long-pressed start), generate 3 to 5 distinct loop suggestions near a target distance, ranked by low-stress riding, ready to preview and navigate.

## Algorithm (on device, no dependencies)
Waypoint-ring search, reusing 06a's reuse-penalty routing:
1. For a target distance D, start with radius r = D / 5.5 (a road loop is longer than its circle).
2. For each of 8 bearings (every 45 degrees, plus a random offset per run), place 2 waypoints at bearing +/- 50 degrees, distance r from the origin, forming a triangle with the origin. Snap waypoints to the graph (skip a candidate if a waypoint fails to snap within 300 m).
3. Route origin to W1 to W2 to origin, applying the 06a reuse penalties cumulatively across legs.
4. Scale r by D / actual distance and retry, at most 3 iterations per bearing, stopping when within tolerance (default 10%).
5. Score in-tolerance candidates: low-stress share (weight 0.5), trail share (0.2), 1 minus overlap share (0.2), distance fit (0.1). Apply hard filters: `maxLTS`, and `minTrailShare` when strict.
6. Diversity: drop any candidate sharing more than 50% of its distance with a higher-ranked one. Return the top 3 to 5.
7. Run off the main actor, cancellable. **Budget: under 2 s on the simulator** for D = 15 mi; report timing.

## Constraints model
`LoopSearchConstraints`: origin, targetDistanceMeters, tolerance (0.10), maxLTS (optional), preferTrails (Bool), minTrailShare (optional, strict). Elevation is out of scope until there is elevation data; leave a placeholder field and do not fake it.

## Naming
Name each candidate from its dominant named features, for example "Spring Creek and Poudre Trail Loop", from the two longest named runs. Fall back to "<bearing> Loop" ("Northwest Loop").

## UI
- A "Plan a loop" entry point on the map (button near existing controls).
- Sheet: distance slider (3 to 40 mi, default 10), Max LTS (Any / 2 / 1), "Prefer trails" toggle, start = current location (or "Use pin" if one is set). Find Loops button.
- Results list: name, distance, low-stress %, trail %, and a small route thumbnail or color swatch. Tap to preview on the map; Start launches navigation via the existing flow (the loop is a multi-leg `PlannedRoute` with no spoken waypoint cues; waypoints are invisible to the rider).
- Refinement chips under the results: Shorter, Longer (+/- 20%), More trail (sets preferTrails, raises the trail weight). Each re-runs the search.

## Tests (synthetic graphs)
- A ring-road graph: finds a loop within 10% of target.
- Diversity filter removes a near-duplicate candidate.
- maxLTS excludes candidates containing LTS 3+ edges.
- Cancellation stops work promptly.
- Waypoint that cannot snap is skipped, not a crash.

## Done when
- Build succeeds, all tests pass.
- Reply with results for 5, 10, and 20 mi from Old Town (default settings), and 10 mi with Prefer trails: name, distance, low-stress %, trail %, overlap %, and search time for each run.
