# Routing backlog

Known issues and tuning items parked so feature work can continue. Pick up after real-world riding.

## Loop planner (06b)
- **Prefer trails has little effect.** 10 mi from Old Town: default 35% trail, Prefer trails 34% trail, same top loop. Shortlist entries #3+ under Prefer trails came in at 17 to 19% trail, which is backwards. Check first: is "trail %" counting the same edge set the x1.4 penalty exempts (ArcGIS Paved Multiuse Trail plus OSM cycleway/path)? If the metric only counts ArcGIS trails, the two disagree. Then consider ranking with a hard floor (Prefer trails drops candidates below the default run's best trail %) and a stronger multiplier (x1.8).
- **Streaming slowed total search.** 20 mi total went from 5.35 s to 9.13 s after streaming was added (10 mi: 2.98 to 3.44 s). Likely incremental re-sort/diversity work or main-actor publishing per candidate. Batch UI updates (every 250 ms) and run diversity only on publish.
