# Smart Route Planner — Implementation Plan

**Status:** Draft for review  
**Author:** —  
**Last updated:** 2026-06-19  
**Scope:** Fort Collins & Loveland, Colorado (existing BikeNoCo coverage)

---

## 1. Summary

Add a **constraint-based ride planner** that generates loop routes from the rider’s current location, then allows refinement — including natural-language follow-ups such as *“only paved multi-use trails.”*

The core idea is not “AI routing.” It is:

1. Parse rider intent into structured constraints.
2. Search the **local bike infrastructure graph** BikeNoCo already loads.
3. Return several ranked route candidates.
4. Let the rider tighten constraints and re-search without starting over.

Voice and conversational UI are optional layers on top of a reliable structured planner.

---

## 2. Problem Statement

Cyclists in Northern Colorado want rides that match real-world preferences:

- Target distance (e.g. ~15 miles)
- Loop from current location
- Acceptable elevation gain (“moderate”)
- Infrastructure preference (paved trails, low LTS, avoid sharrows, etc.)

Existing apps can route generically, but they do not reason over **BikeNoCo’s enriched facility data** (facility type, LTS, local trail names). BikeNoCo is positioned to offer infrastructure-aware loop planning that generic map apps cannot replicate in this region.

---

## 3. Goals

| Goal | Description |
|------|-------------|
| **G1** | Generate 3–5 loop route suggestions from the user’s current location |
| **G2** | Match target distance within a configurable tolerance (default ±10%) |
| **G3** | Filter and rank by facility type (e.g. paved trail only) |
| **G4** | Support elevation preference bands (easy / moderate / challenging) |
| **G5** | Allow refinement without restarting (“more trail”, “less climbing”) |
| **G6** | Preview selected route on the existing map; navigate/record using existing ride flow |
| **G7** | Work offline after initial network graph is built (on-device search) |

## 4. Non-Goals (v1)

- Nationwide routing outside FC/Loveland data coverage
- Turn-by-turn voice navigation (reuse map preview + optional Apple Maps handoff later)
- Social sharing, saved routes library, or route editing by drawing
- Full conversational AI as the **primary** interface (structured UI first)
- Real-time traffic or road closure integration
- Guaranteed 100% trail coverage unless user explicitly selects a strict mode

---

## 5. Current Codebase (Starting Point)

### What exists today

| Component | Location | Relevance |
|-----------|----------|-----------|
| `BikeRoute` + `FacilityType` | `BikeNoCo/Models/BikeRoute.swift` | Segment geometry, type, LTS, speed |
| ArcGIS ingestion | `BikeNoCo/Services/ArcGISService.swift` | ~5k segments from FC, Loveland, trails |
| Map rendering | `BikeNoCo/Views/BikeMapView.swift` | Polyline overlays, active route highlight |
| Static suggested rides | `RideWithGPSService.swift` | Curated loops; not dynamic |
| Filters | `FilterView.swift`, `MapViewModel` | Toggle facility visibility — pattern for constraint UI |
| Ride recording | `RideRecorder.swift` | Can attach to a planned route post-selection |

### Gaps

- No graph topology (segments are not linked at intersections)
- No elevation profile per segment
- No route search / ranking engine
- No structured “plan a ride” model or UI
- No intent parsing (NL or form-based)

---

## 6. User Experience (Target)

### 6.1 Primary flow (v1 — structured UI)

```
[Plan a Ride]  (new entry point on map or filter sheet)
     ↓
┌─────────────────────────────────────┐
│  Distance:    [====●====] 15 mi     │
│  Shape:       (●) Loop  ( ) Out & back │
│  Elevation:   ( ) Easy (●) Moderate ( ) Hard │
│  Surface:     [x] Paved trails  [x] Bike lanes … │
│  Max LTS:     [====●====] LTS 2     │
│                                     │
│         [ Find Routes ]             │
└─────────────────────────────────────┘
     ↓
Results list (3–5 cards):
  • River Loop — 14.8 mi · +820 ft · 72% paved trail · LTS 1–2
  • Spring Creek — 15.4 mi · +640 ft · 58% paved trail · LTS 1–2
     ↓
Tap result → preview on map (reuse `activeRoute` pattern)
     ↓
[ Start Ride ] → optional handoff to recorder
```

### 6.2 Refinement flow (v1.5)

After initial results, show quick refinement chips:

- *More trail*
- *Less elevation*
- *Shorter / Longer*
- *Stricter surface filter*

Each chip adjusts `RouteSearchConstraints` and re-runs search.

### 6.3 Conversational flow (v2 — optional)

```
User: "Find me a 15-mile loop with moderate hills from here."
App:  → parses to RouteSearchConstraints
      → shows 4 suggestions

User: "Only paved multi-use trails."
App:  → adds facility filter, re-ranks / re-searches
      → "Here are 3 routes that stay on paved trails for 85%+ of the ride."
```

**Implementation note:** v2 should call the same `RoutePlannerService` as v1. NL is an input adapter, not a separate routing system.

---

## 7. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  UI Layer                                                    │
│  PlanRideView · RouteResultsView · RefinementChips           │
│  (v2) Voice/TextIntentView → IntentParser                    │
└───────────────────────────┬──────────────────────────────────┘
                            │ RouteSearchConstraints
                            ▼
┌──────────────────────────────────────────────────────────────┐
│  RoutePlannerService                                         │
│  · snap user location to graph                               │
│  · run loop search                                           │
│  · score & rank candidates                                   │
│  · apply refinement deltas                                   │
└───────────────────────────┬──────────────────────────────────┘
                            │
          ┌─────────────────┼─────────────────┐
          ▼                 ▼                 ▼
┌─────────────────┐ ┌───────────────┐ ┌──────────────────┐
│ BikeNetworkGraph│ │ ElevationSvc  │ │ RouteCandidate   │
│ (built from     │ │ (DEM / API /  │ │ (model + scoring)│
│  BikeRoute[])   │ │  cached)      │ │                  │
└─────────────────┘ └───────────────┘ └──────────────────┘
          ▲
          │ BikeRoute[] from ArcGISService (existing)
```

### New modules (proposed)

```
BikeNoCo/
├── Models/
│   ├── RouteSearchConstraints.swift
│   ├── RouteCandidate.swift
│   └── BikeNetworkGraph.swift      # graph types only
├── Services/
│   ├── BikeNetworkGraphBuilder.swift
│   ├── RoutePlannerService.swift
│   ├── RouteScoringService.swift
│   └── ElevationService.swift
├── ViewModels/
│   └── RoutePlannerViewModel.swift
└── Views/
    ├── PlanRideView.swift
    └── RouteResultsView.swift
```

---

## 8. Data Models

### 8.1 `RouteSearchConstraints`

```swift
struct RouteSearchConstraints: Equatable {
    var origin: CLLocationCoordinate2D
    var targetDistanceMeters: Double
    var distanceTolerance: Double          // default 0.10 (±10%)
    var shape: RouteShape                  // .loop | .outAndBack (v1: loop only)
    var elevationPreference: ElevationBand // .easy | .moderate | .challenging | .any
    var allowedFacilityTypes: Set<FacilityType>
    var maxLTS: Int?                       // nil = no LTS cap
    var minTrailPercentage: Double?        // 0.0–1.0, for “mostly trail” requests
    var strictSurfaceMatch: Bool           // if true, reject routes below minTrailPercentage
}

enum ElevationBand {
    case easy       // e.g.  < 30 ft/mi
    case moderate   // e.g.  30–70 ft/mi
    case challenging // e.g. > 70 ft/mi
    case any
}
```

### 8.2 `RouteCandidate`

```swift
struct RouteCandidate: Identifiable {
    let id: UUID
    let name: String                       // generated, e.g. "Spring Creek Loop"
    let segmentIDs: [UUID]                 // BikeRoute ids in traversal order
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
    let elevationGainMeters: Double
    let elevationLossMeters: Double
    let facilityBreakdown: [FacilityType: Double]  // meters per type
    let maxLTS: Int
    let score: Double
    let matchExplanation: String           // "72% paved trail · LTS 1–2"
}
```

### 8.3 Graph types

```swift
struct GraphNode: Hashable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
}

struct GraphEdge {
    let routeID: UUID
    let from: Int
    let to: Int
    let lengthMeters: Double
    let facilityType: FacilityType
    let lts: Int?
    let elevationGainMeters: Double        // populated by ElevationService
    let geometry: [CLLocationCoordinate2D]
    let bidirectional: Bool                // trails often true; some bike lanes one-way
}
```

---

## 9. Bike Network Graph Construction

### 9.1 Problem

`BikeRoute` segments are independent polylines. Routing requires knowing which segments **connect** at endpoints.

### 9.2 Approach

1. **Endpoint clustering**  
   Snap all segment endpoints within **ε = 8 m** into shared `GraphNode`s (tunable; GPS/ArcGIS precision varies).

2. **Edge creation**  
   For each `BikeRoute` path, create one `GraphEdge` per contiguous path (or split at sharp discontinuities).

3. **Bidirectionality**  
   Default: bidirectional for trails and local streets unless one-way data exists. v1 can treat all edges as bidirectional with a follow-up to respect one-way bike lanes.

4. **Gap healing (optional v1.1)**  
   If two nodes are 8–25 m apart and both are high-quality facilities (paved trail), add a short **connector edge** flagged as `synthetic` so routing does not fail at minor GIS gaps.

5. **User snap**  
   On search, snap user location to nearest graph node within **150 m** (walking distance to network). If none found, return a friendly error: *“No bike infrastructure near your location.”*

### 9.3 Caching

- Build graph once after `ArcGISService.fetchAllRoutes()` completes.
- Persist serialized graph to `Application Support/` keyed by data fetch hash.
- Rebuild when route data changes.

### 9.4 Performance target

- Graph build: < 3 s on iPhone 14 for ~5k segments (background task)
- Search: < 2 s for 3–5 candidates on device

---

## 10. Elevation

ArcGIS segments do not include elevation profiles today.

### Options

| Option | Pros | Cons |
|--------|------|------|
| **A. Open-Elevation / open DEM tile sampling** | Free, offline after cache | Integration work; tile storage |
| **B. Mapbox / Google Elevation API** | Simple API | Cost, network, privacy policy updates |
| **C. Precompute on graph build via Apple MapKit elevation (if available)** | Native | Limited / undocumented for batch use |
| **D. Defer elevation to post-path assembly** | Simpler graph | Less useful during search pruning |

**Recommendation:** Option A or B for v1. Sample elevation at edge endpoints and intermediate points (every ~100 m). Cache edge gain/loss on the graph.

### Elevation bands (defaults — tunable)

| Band | Gain rate |
|------|-----------|
| Easy | < 30 ft/mi (≈ 5.7 m/km) |
| Moderate | 30–70 ft/mi |
| Challenging | > 70 ft/mi |

Display actual feet gained on every candidate so “moderate” never feels opaque.

---

## 11. Route Search Algorithm

Loop routing from a start node with a target circumference is not standard single-pair shortest path. Proposed **generate-and-score** approach for v1:

### Phase 1 — Candidate generation

1. Snap origin → start node `S`.
2. Run **bounded depth-first / beam search** or **randomized cycle walk**:
   - Walk edges without revisiting nodes (or penalize repeats heavily).
   - Track accumulated distance.
   - When partial distance ≥ target × (1 − tolerance), attempt to **return to S** via Dijkstra/A*.
   - Accept closed loop if total distance within `[target × 0.9, target × 1.1]`.
3. Generate up to **30 raw loops**, deduplicate by edge-set similarity (>80% overlap → duplicate).

### Phase 2 — Constraint filtering

Discard loops that violate hard constraints:

- Disallowed `FacilityType` on any edge (if strict mode)
- Any segment LTS > `maxLTS`
- Elevation band mismatch (if not `.any`)
- `trailPercentage < minTrailPercentage` (if strict)

### Phase 3 — Scoring

Weighted score (higher = better):

```
score =
    w1 × distanceFit          // 1.0 at exact target, falls off linearly
  + w2 × elevationFit         // 1.0 at band center
  + w3 × trailPercentage      // if user prefers trails
  + w4 × ltsQuality           // reward lower LTS
  − w5 × overlapPenalty       // penalize ugly backtracking
  − w6 × roadSegmentPenalty   // penalize sharrows / no facility
```

Return top **5** unique candidates.

### Refinement re-search

Refinement chips mutate `RouteSearchConstraints` and re-run Phase 2–3 on cached raw loops **or** trigger a fresh Phase 1 if constraints tightened significantly (e.g. strict paved-only drops candidate pool to zero).

---

## 12. Natural Language Layer (v2)

### Role

Convert utterances → `RouteSearchConstraints` updates.

### Recommended approach

- **On-device or API LLM** with a **strict JSON schema** output:
  ```json
  {
    "targetDistanceMiles": 15,
    "elevationPreference": "moderate",
    "allowedFacilityTypes": ["Paved Multiuse Trail", "Sidepath"],
    "maxLTS": 2,
    "refinement": "stricter_surface"
  }
  ```
- Validate all enums against `FacilityType` raw values; reject hallucinated types.
- Map parsed result into `RouteSearchConstraints`; call existing planner.
- Show parsed constraints to user for confirmation before search (“Searching for 15 mi loop · moderate hills · paved trails”).

### Why not LLM-first

- Routing must be deterministic and testable.
- NL is an input convenience, not the source of truth.

---

## 13. UI Integration

### Entry points

1. **Filter sheet** — new “Plan a Ride” section above Suggested Rides.
2. **Map FAB** — compass or wand icon next to record button (optional).

### Map preview

Reuse existing patterns:

- Set `MapViewModel.activeRouteID` to a synthetic `BikeRoute` built from `RouteCandidate.coordinates`.
- Facility type: `.recommendedRide` or new `.plannedRide` for distinct styling.

### Recording handoff

When user taps **Start Ride** on a planned route:

- Optionally show the route as active overlay during recording (future: compare actual vs planned).

---

## 14. Phased Delivery

### Phase 0 — Spike (1–2 weeks)

- [ ] Build graph from existing `BikeRoute[]`; visualize nodes/edges in debug overlay
- [ ] Measure connectivity (% segments in largest component)
- [ ] Prototype one loop search from fixed point; log distance accuracy

**Exit criteria:** Generate one 10 mi loop on device in FC.

### Phase 1 — Structured planner MVP (3–4 weeks)

- [ ] `RouteSearchConstraints` + `RouteCandidate` models
- [ ] `BikeNetworkGraphBuilder` with caching
- [ ] `ElevationService` (API or DEM)
- [ ] `RoutePlannerService` + scoring
- [ ] `PlanRideView` + `RouteResultsView`
- [ ] Map preview + refinement chips (distance, elevation, surface)

**Exit criteria:** User can find 3+ loop options from current location with facility filters; no voice.

### Phase 2 — Quality & polish (2–3 weeks)

- [ ] Gap healing connectors
- [ ] Better route naming (trail/street names along dominant segments)
- [ ] Empty-state UX (“No routes match — try relaxing filters”)
- [ ] Unit tests for graph builder, scoring, constraint parsing
- [ ] On-device performance profiling

### Phase 3 — Conversational input (2+ weeks, optional)

- [ ] Intent parser → constraints JSON
- [ ] Confirmation UI for parsed intent
- [ ] Follow-up refinements in chat-style sheet

---

## 15. Testing Strategy

| Layer | Tests |
|-------|-------|
| Graph builder | Endpoint snapping, edge count, largest component size |
| Planner | Known synthetic graph → expected loop length |
| Scoring | Constraint violations, ranking order |
| Elevation | Monotonic gain on known hill climb segment |
| UI | Snapshot tests for PlanRideView, results cards |

**Field testing:** Validate 10 manually ridden loops against planned distance ±10% and facility claims.

---

## 16. Privacy & App Store

- Route planning uses location → already covered by existing purpose strings; planner requires **When In Use** location at search time.
- If v2 uses cloud LLM: disclose in Privacy Nutrition Label; add opt-in if sending location + query off-device.
- If elevation API used: network disclosure; no new account required.

---

## 17. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| GIS gaps break loops | No results | Connector edges; snap tolerance; clear UX |
| Slow on-device search | Bad UX | Cap raw loops; cache graph; background pre-build |
| “Paved only” too strict | Zero results | Default to *maximize* trail %; strict mode opt-in |
| Elevation API cost/latency | Slow planning | Cache edge elevation on graph build |
| Subjective “moderate” | User trust issues | Always show actual ft gained |
| One-way streets wrong | Illegal routing | v1.1: ingest directionality from ArcGIS if available |

---

## 18. Open Questions (for review)

1. **Strict vs soft surface matching** — Should “paved trail only” mean 100% of edges, or ≥80% of mileage with no LTS 3+ on the remainder?
2. **Out-and-back** — Include in v1 or defer to loop-only?
3. **LTS vs facility type** — If user says “safe route,” map to LTS ≤2, trail preference, or both?
4. **Naming** — Auto-generate from dominant trail names, or generic “Route A / B / C”?
5. **Offline** — Must elevation work offline, or is network OK for v1?
6. **Cloud** — Is an LLM API acceptable for v2, or on-device only (Apple Foundation Models)?
7. **Scope creep** — Should planned routes be saveable/shareable in v1?

---

## 19. Success Metrics

- ≥70% of test searches return ≥3 candidates within 5 s
- Median distance error ≤10% vs target on field-validated loops
- Facility claims accurate on ≥90% of sampled segments (manual audit)
- User can apply a refinement and get new results in ≤3 s

---

## 20. Appendix: Example Constraint Mappings

| User phrase | Constraint change |
|-------------|-------------------|
| “15-mile loop” | `targetDistanceMeters = 24140`, `shape = .loop` |
| “moderate hills” | `elevationPreference = .moderate` |
| “paved multi-use trail only” | `allowedFacilityTypes = [.pavedTrail]`, `minTrailPercentage = 0.95`, `strictSurfaceMatch = true` |
| “keep it low stress” | `maxLTS = 2` |
| “more trail” | increase `minTrailPercentage`, boost `w3` trail weight |
| “flatter” | `elevationPreference = .easy` |
| “a bit shorter” | `targetDistanceMeters × 0.85` |

---

## 21. Related Files (existing)

- `BikeNoCo/Models/BikeRoute.swift` — segment model & `FacilityType`
- `BikeNoCo/Services/ArcGISService.swift` — data ingestion
- `BikeNoCo/ViewModels/MapViewModel.swift` — active route & filters
- `BikeNoCo/Views/FilterView.swift` — UI pattern for facility toggles
- `BikeNoCo/Views/BikeMapView.swift` — route overlay rendering

---

*End of draft — feedback welcome on open questions in §18 before Phase 0 spike.*
