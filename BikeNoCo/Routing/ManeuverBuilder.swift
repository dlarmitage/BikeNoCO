import Foundation
import CoreLocation

enum ManeuverBuilder {
    private static let bearingSpanMeters = 30.0
    private static let collapseMeters = 20.0
    private static let shortEdgeMeters = 20.0
    private static let unnamedInheritMeters = 60.0
    private static let continueMinRunMeters = 150.0
    private static let abaMaxLengthMeters = 150.0
    private static let abaMaxHeadingDeltaDegrees = 30.0
    private static let straightDegrees = 25.0
    private static let slightDegrees = 60.0
    private static let turnDegrees = 135.0
    private static let uTurnDegrees = 160.0
    private static let departNamedSearchMeters = 60.0
    private static let finalUnnamedFoldMeters = 60.0
    private static let inRunTurnWindowMeters = 50.0
    private static let inRunSampleMeters = 5.0
    private static let earlyNameMergeMeters = 50.0

    private static let pathKey = "__path__"
    private static let streetKey = "__street__"

    fileprivate struct EdgeSpan {
        let start: Double
        let end: Double
        let isSynthetic: Bool
    }

    /// Debug snapshot of a name-run after short/synthetic absorb, before A-B-A.
    struct DiagnoseRun: Sendable {
        let displayName: String?
        let compareKey: String
        let lengthMeters: Double
        let startDistanceAlong: Double
        let endDistanceAlong: Double
        let isNamed: Bool
        let rawEdgeNames: [String]
    }

    static func diagnoseRuns(for route: PlannedRoute) -> [DiagnoseRun] {
        let annotated = annotate(edges: route.edges)
        var runs = buildRuns(annotated)
        runs = absorbShortAndSyntheticRuns(runs)
        return runs.map { run in
            DiagnoseRun(
                displayName: run.displayName,
                compareKey: run.compareKey,
                lengthMeters: run.lengthMeters,
                startDistanceAlong: run.startDistanceAlong,
                endDistanceAlong: run.endDistanceAlong,
                isNamed: run.isNamed,
                rawEdgeNames: run.edges.map(\.name)
            )
        }
    }

    static func diagnoseDepartBearing(for route: PlannedRoute) -> Double {
        guard route.coordinates.count >= 2 else { return 0 }
        let edgeSpans = buildEdgeSpans(edges: route.edges)
        let polyline = PolylineIndex(coordinates: route.coordinates)
        return polyline.bearingSkippingSynthetic(
            fromDistance: 0,
            towardIncreasing: true,
            spanMeters: bearingSpanMeters,
            edgeSpans: edgeSpans
        ) ?? 0
    }

    static func diagnoseFinalHeading(for route: PlannedRoute) -> Double {
        guard route.coordinates.count >= 2 else { return 0 }
        let edgeSpans = buildEdgeSpans(edges: route.edges)
        let polyline = PolylineIndex(coordinates: route.coordinates)
        return polyline.bearingSkippingSynthetic(
            fromDistance: polyline.length,
            towardIncreasing: false,
            spanMeters: bearingSpanMeters,
            edgeSpans: edgeSpans
        ) ?? 0
    }

    static func build(from route: PlannedRoute) -> [Maneuver] {
        guard !route.edges.isEmpty, route.coordinates.count >= 2 else {
            return [
                Maneuver(
                    type: .depart,
                    coordinate: route.origin,
                    distanceAlongRoute: 0,
                    distanceToNext: route.totalDistanceMeters,
                    streetName: nil,
                    instruction: "Head north",
                    turnAngleDegrees: nil
                ),
                Maneuver(
                    type: .arrive,
                    coordinate: route.destination,
                    distanceAlongRoute: route.totalDistanceMeters,
                    distanceToNext: 0,
                    streetName: nil,
                    instruction: "Arrive at destination",
                    turnAngleDegrees: nil
                )
            ]
        }

        let edgeSpans = buildEdgeSpans(edges: route.edges)
        let annotated = annotate(edges: route.edges)
        var runs = buildRuns(annotated)
        runs = absorbShortAndSyntheticRuns(runs)
        runs = absorbABADetours(runs, edgeSpans: edgeSpans, coordinates: route.coordinates)
        runs = foldTrailingUnnamed(runs)

        let polyline = PolylineIndex(coordinates: route.coordinates)
        var drafts: [Draft] = []

        let departBearing = polyline.bearingSkippingSynthetic(
            fromDistance: 0,
            towardIncreasing: true,
            spanMeters: bearingSpanMeters,
            edgeSpans: edgeSpans
        ) ?? 0
        let departName = firstNamedDisplay(within: departNamedSearchMeters, runs: runs)
        drafts.append(
            Draft(
                type: .depart,
                distanceAlong: 0,
                coordinate: polyline.coordinate(at: 0) ?? route.origin,
                streetName: departName,
                instruction: departInstruction(bearing: departBearing, name: departName),
                turnAngleDegrees: nil
            )
        )

        var suppressedBoundaries: Set<Int> = [] // run index whose entry cue is merged into an early in-run turn

        // Detect in-run corners first so early ones can suppress the name-entry cue.
        var inRunDrafts: [Draft] = []
        for (runIndex, run) in runs.enumerated() {
            let isNewName = runIndex > 0 && runs[runIndex - 1].compareKey != run.compareKey
            var corners = interiorCorners(run: run, polyline: polyline, edgeSpans: edgeSpans)

            // Dedicated early scan: catches a ≥60° bend in the first 50 m of a new name
            // even when the broader walker skips it (short approach leg, etc.).
            if isNewName,
               let early = firstTurn(
                in: run,
                within: earlyNameMergeMeters,
                polyline: polyline
               ),
               !corners.contains(where: { abs($0.distance - early.distance) < collapseMeters }) {
                corners.insert(early, at: 0)
            }

            for corner in corners {
                let fromStart = corner.distance - run.startDistanceAlong
                let mergeOnto = isNewName && fromStart <= earlyNameMergeMeters
                if mergeOnto {
                    suppressedBoundaries.insert(runIndex)
                }
                let streetName = run.displayName
                inRunDrafts.append(
                    Draft(
                        type: corner.type,
                        distanceAlong: corner.distance,
                        coordinate: polyline.coordinate(at: corner.distance) ?? run.startCoordinate,
                        streetName: streetName,
                        instruction: mergeOnto
                            ? instruction(type: corner.type, streetName: streetName)
                            : stayOnInstruction(type: corner.type, streetName: streetName),
                        turnAngleDegrees: corner.signed
                    )
                )
            }
        }

        if runs.count >= 2 {
            for index in 0..<(runs.count - 1) {
                let nextIndex = index + 1
                if suppressedBoundaries.contains(nextIndex) { continue }

                let current = runs[index]
                let next = runs[nextIndex]
                let boundary = current.endDistanceAlong

                let bearingIn = polyline.bearingSkippingSynthetic(
                    fromDistance: boundary,
                    towardIncreasing: false,
                    spanMeters: bearingSpanMeters,
                    edgeSpans: edgeSpans
                )
                let bearingOut = polyline.bearingSkippingSynthetic(
                    fromDistance: boundary,
                    towardIncreasing: true,
                    spanMeters: bearingSpanMeters,
                    edgeSpans: edgeSpans
                )
                guard let bearingIn, let bearingOut else { continue }

                let signed = signedTurnDegrees(incoming: bearingIn, outgoing: bearingOut)
                let turnClass = classify(abs(signed))
                let nameChanged = current.compareKey != next.compareKey

                let type: ManeuverType?
                switch turnClass {
                case .straight:
                    if nameChanged, next.lengthMeters >= continueMinRunMeters, !isGenericKey(next.compareKey) {
                        type = .continue
                    } else {
                        type = nil
                    }
                case .slight:
                    if nameChanged {
                        type = signed < 0 ? .slightLeft : .slightRight
                    } else {
                        type = nil
                    }
                case .turn:
                    type = signed < 0 ? .left : .right
                case .sharp:
                    type = signed < 0 ? .sharpLeft : .sharpRight
                case .uTurn:
                    type = .uTurn
                }

                guard let type else { continue }
                let streetName = next.displayName
                drafts.append(
                    Draft(
                        type: type,
                        distanceAlong: boundary,
                        coordinate: polyline.coordinate(at: boundary) ?? next.startCoordinate,
                        streetName: streetName,
                        instruction: instruction(type: type, streetName: streetName),
                        turnAngleDegrees: signed
                    )
                )
            }
        }

        drafts.append(contentsOf: inRunDrafts)
        drafts.sort { $0.distanceAlong < $1.distanceAlong }

        drafts.append(
            Draft(
                type: .arrive,
                distanceAlong: polyline.length,
                coordinate: polyline.coordinate(at: polyline.length) ?? route.destination,
                streetName: nil,
                instruction: "Arrive at destination",
                turnAngleDegrees: nil
            )
        )

        return finalize(collapse(drafts))
    }

    // MARK: - In-run corners

    private struct InteriorCorner {
        let distance: Double
        let signed: Double
        let type: ManeuverType
    }

    /// Strongest ≥60° corner in the first `limitMeters` of a run (for onto-merge wording).
    private static func firstTurn(
        in run: Run,
        within limitMeters: Double,
        polyline: PolylineIndex
    ) -> InteriorCorner? {
        let start = run.startDistanceAlong
        let end = run.endDistanceAlong
        guard end - start > 10 else { return nil }

        var best: InteriorCorner?
        var distance = start + 5
        let last = min(end - 5, start + limitMeters + bearingSpanMeters)
        while distance <= last {
            let back = max(start, distance - bearingSpanMeters)
            let forward = min(end, distance + bearingSpanMeters)
            if forward - distance >= 5, distance - back >= 5,
               let bearingIn = polyline.bearing(fromDistance: back, toDistance: distance),
               let bearingOut = polyline.bearing(fromDistance: distance, toDistance: forward) {
                let signed = signedTurnDegrees(incoming: bearingIn, outgoing: bearingOut)
                let absTurn = abs(signed)
                if absTurn >= slightDegrees,
                   distance - start <= limitMeters {
                    let turnClass = classify(absTurn)
                    if turnClass == .turn || turnClass == .sharp || turnClass == .uTurn {
                        let type: ManeuverType
                        switch turnClass {
                        case .turn: type = signed < 0 ? .left : .right
                        case .sharp: type = signed < 0 ? .sharpLeft : .sharpRight
                        case .uTurn: type = .uTurn
                        default: type = signed < 0 ? .left : .right
                        }
                        if let current = best {
                            if absTurn > abs(current.signed) {
                                best = InteriorCorner(distance: distance, signed: signed, type: type)
                            }
                        } else {
                            best = InteriorCorner(distance: distance, signed: signed, type: type)
                        }
                    }
                }
            }
            distance += inRunSampleMeters
        }
        return best
    }

    /// Walk a run with 30 m smoothed bearings; emit where heading changes by ≥60° within 50 m.
    private static func interiorCorners(
        run: Run,
        polyline: PolylineIndex,
        edgeSpans: [EdgeSpan]
    ) -> [InteriorCorner] {
        let start = run.startDistanceAlong
        let end = run.endDistanceAlong
        // Keep forward bearings inside this run so we don't peek into the next name.
        let headingLast = end - bearingSpanMeters
        guard headingLast - start > inRunTurnWindowMeters else { return [] }

        // Forward heading at each sample (30 m smoothed, clamped to the run).
        var headings: [(distance: Double, heading: Double)] = []
        var distance = start
        while distance <= headingLast {
            let span = min(bearingSpanMeters, end - distance)
            if span >= 5,
               let heading = polyline.bearing(
                fromDistance: distance,
                toDistance: distance + span
               ) {
                // Skip if the span crosses synthetic interior.
                let mid = distance + span * 0.5
                let onSynthetic = edgeSpans.contains {
                    $0.isSynthetic && mid > $0.start + 1e-6 && mid < $0.end - 1e-6
                }
                if !onSynthetic {
                    headings.append((distance, heading))
                }
            }
            distance += inRunSampleMeters
        }
        guard headings.count >= 2 else { return [] }

        // Delta between heading at d and heading ~50 m ahead (still inside the run).
        var windowTurns: [(distance: Double, signed: Double)] = []
        for sample in headings {
            guard let ahead = headings.first(where: {
                $0.distance >= sample.distance + inRunTurnWindowMeters - 1
            }) else { continue }
            let span = ahead.distance - sample.distance
            guard span >= inRunTurnWindowMeters * 0.6 else { continue }
            let signed = signedTurnDegrees(incoming: sample.heading, outgoing: ahead.heading)
            windowTurns.append((sample.distance, signed))
        }

        // Also sample localized apexes (30 m back / forward) clamped to the run.
        var localTurns: [(distance: Double, signed: Double)] = []
        distance = start + bearingSpanMeters
        while distance <= end - bearingSpanMeters {
            let back = max(start, distance - bearingSpanMeters)
            let forward = min(end, distance + bearingSpanMeters)
            if let bearingIn = polyline.bearing(fromDistance: back, toDistance: distance),
               let bearingOut = polyline.bearing(fromDistance: distance, toDistance: forward) {
                localTurns.append(
                    (distance, signedTurnDegrees(incoming: bearingIn, outgoing: bearingOut))
                )
            }
            distance += inRunSampleMeters
        }

        func peaks(
            from turns: [(distance: Double, signed: Double)],
            placeAtMidWindow: Bool
        ) -> [InteriorCorner] {
            guard turns.count >= 3 else { return [] }
            var result: [InteriorCorner] = []
            for index in 1..<(turns.count - 1) {
                let sample = turns[index]
                let absTurn = abs(sample.signed)
                guard absTurn >= slightDegrees else { continue }
                let turnClass = classify(absTurn)
                guard turnClass == .turn || turnClass == .sharp || turnClass == .uTurn else {
                    continue
                }
                let prev = abs(turns[index - 1].signed)
                let next = abs(turns[index + 1].signed)
                guard absTurn + 0.5 >= prev, absTurn + 0.5 >= next else { continue }

                let type: ManeuverType
                switch turnClass {
                case .turn:
                    type = sample.signed < 0 ? .left : .right
                case .sharp:
                    type = sample.signed < 0 ? .sharpLeft : .sharpRight
                case .uTurn:
                    type = .uTurn
                default:
                    continue
                }
                let placed: Double
                if placeAtMidWindow {
                    placed = min(sample.distance + inRunTurnWindowMeters * 0.5, headingLast)
                } else {
                    placed = sample.distance
                }
                result.append(InteriorCorner(distance: placed, signed: sample.signed, type: type))
            }
            return result
        }

        var combined = peaks(from: windowTurns, placeAtMidWindow: true)
        combined.append(contentsOf: peaks(from: localTurns, placeAtMidWindow: false))
        combined.sort { $0.distance < $1.distance }

        let clustered = suppressCompensatingCorners(clusterCorners(combined))
        return dropTransientJogs(
            clustered,
            run: run,
            polyline: polyline,
            edgeSpans: edgeSpans
        )
    }

    private static func clusterCorners(_ candidates: [InteriorCorner]) -> [InteriorCorner] {
        guard !candidates.isEmpty else { return [] }
        var result: [InteriorCorner] = []
        var cluster: [InteriorCorner] = [candidates[0]]

        for candidate in candidates.dropFirst() {
            if candidate.distance - cluster[0].distance < inRunTurnWindowMeters {
                cluster.append(candidate)
            } else {
                if let best = cluster.max(by: { abs($0.signed) < abs($1.signed) }) {
                    result.append(best)
                }
                cluster = [candidate]
            }
        }
        if let best = cluster.max(by: { abs($0.signed) < abs($1.signed) }) {
            result.append(best)
        }
        return result
    }

    /// Drop opposite-turn pairs within 150 m whose net is nearly straight (absorbed jogs).
    private static func suppressCompensatingCorners(_ corners: [InteriorCorner]) -> [InteriorCorner] {
        var kept = corners
        var index = 0
        while index < kept.count - 1 {
            let first = kept[index]
            let second = kept[index + 1]
            let opposite = first.signed * second.signed < 0
            let close = second.distance - first.distance < abaMaxLengthMeters
            let netSmall = abs(first.signed + second.signed) < abaMaxHeadingDeltaDegrees
            if opposite, close, netSmall {
                kept.remove(at: index + 1)
                kept.remove(at: index)
                if index > 0 { index -= 1 }
                continue
            }
            index += 1
        }
        return kept
    }

    /// Drop corners that are undone within ~80–150 m (path / weave jogs).
    private static func dropTransientJogs(
        _ corners: [InteriorCorner],
        run: Run,
        polyline: PolylineIndex,
        edgeSpans: [EdgeSpan]
    ) -> [InteriorCorner] {
        corners.filter { corner in
            // Early-in-run corners merge with the name-entry cue — never treat as jogs.
            if corner.distance - run.startDistanceAlong <= earlyNameMergeMeters {
                return true
            }

            let preStart = max(
                run.startDistanceAlong,
                corner.distance - inRunTurnWindowMeters - bearingSpanMeters
            )
            let preEnd = min(corner.distance - 5, preStart + bearingSpanMeters)
            guard preEnd - preStart >= 5,
                  let headingPre = polyline.bearing(fromDistance: preStart, toDistance: preEnd)
            else { return true }

            let probes = [
                min(run.endDistanceAlong, corner.distance + 80),
                min(run.endDistanceAlong, corner.distance + abaMaxLengthMeters)
            ]
            for probe in probes {
                guard probe - corner.distance >= inRunTurnWindowMeters else { continue }
                let laterEnd = min(run.endDistanceAlong, probe + bearingSpanMeters)
                guard laterEnd - probe >= 5,
                      let headingLater = polyline.bearing(fromDistance: probe, toDistance: laterEnd)
                else { continue }
                let recovered = abs(signedTurnDegrees(incoming: headingPre, outgoing: headingLater))
                    < abaMaxHeadingDeltaDegrees
                if recovered { return false }
            }
            return true
        }
    }

    // MARK: - Edge spans

    private static func buildEdgeSpans(edges: [GraphEdge]) -> [EdgeSpan] {
        var spans: [EdgeSpan] = []
        var traveled = 0.0
        for edge in edges {
            let end = traveled + edge.lengthMeters
            spans.append(
                EdgeSpan(
                    start: traveled,
                    end: end,
                    isSynthetic: edge.isConnector && edge.osmClass == nil
                )
            )
            traveled = end
        }
        return spans
    }

    // MARK: - Annotation / runs

    private struct AnnotatedEdge {
        let edge: GraphEdge
        let compareKey: String
        let displayName: String?
        let isSynthetic: Bool
        let isNamed: Bool
    }

    private struct Run {
        var edges: [GraphEdge]
        var compareKey: String
        var displayName: String?
        var lengthMeters: Double
        var startDistanceAlong: Double
        var endDistanceAlong: Double
        var isSyntheticOnly: Bool
        var isNamed: Bool
        var startCoordinate: CLLocationCoordinate2D

        var isAbsorbable: Bool {
            isSyntheticOnly || lengthMeters < shortEdgeMeters
        }
    }

    private static func isGenericKey(_ key: String) -> Bool {
        key == pathKey || key == streetKey
    }

    private static func annotate(edges: [GraphEdge]) -> [AnnotatedEdge] {
        var result: [AnnotatedEdge] = []
        var lastNamedKey: String?
        var lastNamedDisplay: String?
        var unnamedStreak = 0.0

        for edge in edges {
            let raw = edge.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let synthetic = edge.isConnector && edge.osmClass == nil
            let pathLike = isPathLike(edge)

            if raw.isEmpty {
                unnamedStreak += edge.lengthMeters
                if unnamedStreak <= unnamedInheritMeters, let key = lastNamedKey {
                    result.append(
                        AnnotatedEdge(
                            edge: edge,
                            compareKey: key,
                            displayName: lastNamedDisplay,
                            isSynthetic: synthetic,
                            isNamed: false
                        )
                    )
                } else {
                    let key = pathLike ? pathKey : streetKey
                    let display = pathLike ? "the path" : "the street"
                    result.append(
                        AnnotatedEdge(
                            edge: edge,
                            compareKey: key,
                            displayName: display,
                            isSynthetic: synthetic,
                            isNamed: false
                        )
                    )
                }
            } else {
                unnamedStreak = 0
                let key = NameNormalizer.normalize(raw)
                let display = NameNormalizer.displayName(raw)
                lastNamedKey = key
                lastNamedDisplay = display
                result.append(
                    AnnotatedEdge(
                        edge: edge,
                        compareKey: key,
                        displayName: display,
                        isSynthetic: synthetic,
                        isNamed: true
                    )
                )
            }
        }
        return result
    }

    private static func buildRuns(_ annotated: [AnnotatedEdge]) -> [Run] {
        guard !annotated.isEmpty else { return [] }
        var runs: [Run] = []
        var traveled = 0.0

        for item in annotated {
            let startCoord = item.edge.geometry.first
                ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
            if var last = runs.last, last.compareKey == item.compareKey {
                last.edges.append(item.edge)
                last.lengthMeters += item.edge.lengthMeters
                last.endDistanceAlong = traveled + item.edge.lengthMeters
                last.isSyntheticOnly = last.isSyntheticOnly && item.isSynthetic
                last.isNamed = last.isNamed || item.isNamed
                if let incoming = item.displayName, let existing = last.displayName {
                    last.displayName = NameNormalizer.preferDisplay(existing, incoming)
                } else if last.displayName == nil {
                    last.displayName = item.displayName
                }
                runs[runs.count - 1] = last
            } else {
                runs.append(
                    Run(
                        edges: [item.edge],
                        compareKey: item.compareKey,
                        displayName: item.displayName,
                        lengthMeters: item.edge.lengthMeters,
                        startDistanceAlong: traveled,
                        endDistanceAlong: traveled + item.edge.lengthMeters,
                        isSyntheticOnly: item.isSynthetic,
                        isNamed: item.isNamed,
                        startCoordinate: startCoord
                    )
                )
            }
            traveled += item.edge.lengthMeters
        }
        return runs
    }

    private static func absorbShortAndSyntheticRuns(_ runs: [Run]) -> [Run] {
        guard runs.count > 1 else { return runs }
        var result: [Run] = []

        for run in runs {
            if run.isAbsorbable, var previous = result.last {
                previous.edges.append(contentsOf: run.edges)
                previous.lengthMeters += run.lengthMeters
                previous.endDistanceAlong = run.endDistanceAlong
                previous.isSyntheticOnly = previous.isSyntheticOnly && run.isSyntheticOnly
                previous.isNamed = previous.isNamed || run.isNamed
                result[result.count - 1] = previous
                continue
            }
            result.append(run)
        }

        while result.count >= 2, result[0].isAbsorbable {
            var first = result.removeFirst()
            var next = result[0]
            first.edges.append(contentsOf: next.edges)
            next.edges = first.edges
            next.lengthMeters += first.lengthMeters
            next.startDistanceAlong = first.startDistanceAlong
            next.startCoordinate = first.startCoordinate
            next.isSyntheticOnly = first.isSyntheticOnly && next.isSyntheticOnly
            next.isNamed = first.isNamed || next.isNamed
            result[0] = next
        }

        return compactSameKeyRuns(result)
    }

    /// A-B-A: short middle run flanked by same name with small net heading change → absorb.
    private static func absorbABADetours(
        _ runs: [Run],
        edgeSpans: [EdgeSpan],
        coordinates: [CLLocationCoordinate2D]
    ) -> [Run] {
        guard runs.count >= 3 else { return runs }
        let polyline = PolylineIndex(coordinates: coordinates)
        var current = runs

        var changed = true
        while changed {
            changed = false
            var index = 1
            while index < current.count - 1 {
                let before = current[index - 1]
                let middle = current[index]
                let after = current[index + 1]
                let eligible = middle.lengthMeters < abaMaxLengthMeters
                    && before.compareKey == after.compareKey
                    && !isGenericKey(before.compareKey)

                if eligible {
                    let headingBefore = polyline.bearingSkippingSynthetic(
                        fromDistance: before.endDistanceAlong,
                        towardIncreasing: false,
                        spanMeters: bearingSpanMeters,
                        edgeSpans: edgeSpans
                    )
                    let headingAfter = polyline.bearingSkippingSynthetic(
                        fromDistance: after.startDistanceAlong,
                        towardIncreasing: true,
                        spanMeters: bearingSpanMeters,
                        edgeSpans: edgeSpans
                    )
                    // Net turn through the hop (into middle + out of middle) — absorbs
                    // path hops that leave with nearly the same heading they entered with.
                    let intoMiddleIn = polyline.bearingSkippingSynthetic(
                        fromDistance: middle.startDistanceAlong,
                        towardIncreasing: false,
                        spanMeters: bearingSpanMeters,
                        edgeSpans: edgeSpans
                    )
                    let intoMiddleOut = polyline.bearingSkippingSynthetic(
                        fromDistance: middle.startDistanceAlong,
                        towardIncreasing: true,
                        spanMeters: bearingSpanMeters,
                        edgeSpans: edgeSpans
                    )
                    let outMiddleIn = polyline.bearingSkippingSynthetic(
                        fromDistance: middle.endDistanceAlong,
                        towardIncreasing: false,
                        spanMeters: bearingSpanMeters,
                        edgeSpans: edgeSpans
                    )
                    let outMiddleOut = polyline.bearingSkippingSynthetic(
                        fromDistance: middle.endDistanceAlong,
                        towardIncreasing: true,
                        spanMeters: bearingSpanMeters,
                        edgeSpans: edgeSpans
                    )

                    var shouldAbsorb = false
                    if let headingBefore, let headingAfter {
                        let delta = abs(signedTurnDegrees(incoming: headingBefore, outgoing: headingAfter))
                        if delta < abaMaxHeadingDeltaDegrees {
                            shouldAbsorb = true
                        }
                    }
                    if !shouldAbsorb,
                       let intoMiddleIn, let intoMiddleOut,
                       let outMiddleIn, let outMiddleOut {
                        let net = signedTurnDegrees(incoming: intoMiddleIn, outgoing: intoMiddleOut)
                            + signedTurnDegrees(incoming: outMiddleIn, outgoing: outMiddleOut)
                        if abs(net) < abaMaxHeadingDeltaDegrees {
                            shouldAbsorb = true
                        }
                    }

                    if shouldAbsorb {
                        var merged = before
                        merged.edges.append(contentsOf: middle.edges)
                        merged.edges.append(contentsOf: after.edges)
                        merged.lengthMeters = before.lengthMeters + middle.lengthMeters + after.lengthMeters
                        merged.endDistanceAlong = after.endDistanceAlong
                        merged.isSyntheticOnly = before.isSyntheticOnly
                            && middle.isSyntheticOnly
                            && after.isSyntheticOnly
                        merged.isNamed = before.isNamed || middle.isNamed || after.isNamed
                        if let a = after.displayName, let b = before.displayName {
                            merged.displayName = NameNormalizer.preferDisplay(b, a)
                        }
                        current.replaceSubrange((index - 1)...(index + 1), with: [merged])
                        changed = true
                        continue
                    }
                }
                index += 1
            }
            if changed {
                current = compactSameKeyRuns(current)
            }
        }
        return current
    }

    private static func foldTrailingUnnamed(_ runs: [Run]) -> [Run] {
        guard runs.count >= 2 else { return runs }
        var result = runs
        while result.count >= 2 {
            let last = result[result.count - 1]
            let unnamed = !last.isNamed || isGenericKey(last.compareKey)
            guard unnamed, last.lengthMeters < finalUnnamedFoldMeters else { break }
            var previous = result[result.count - 2]
            previous.edges.append(contentsOf: last.edges)
            previous.lengthMeters += last.lengthMeters
            previous.endDistanceAlong = last.endDistanceAlong
            previous.isSyntheticOnly = previous.isSyntheticOnly && last.isSyntheticOnly
            result.removeLast()
            result[result.count - 1] = previous
        }
        return result
    }

    private static func compactSameKeyRuns(_ runs: [Run]) -> [Run] {
        var compacted: [Run] = []
        for run in runs {
            if var last = compacted.last, last.compareKey == run.compareKey {
                last.edges.append(contentsOf: run.edges)
                last.lengthMeters += run.lengthMeters
                last.endDistanceAlong = run.endDistanceAlong
                last.isSyntheticOnly = last.isSyntheticOnly && run.isSyntheticOnly
                last.isNamed = last.isNamed || run.isNamed
                if let incoming = run.displayName, let existing = last.displayName {
                    last.displayName = NameNormalizer.preferDisplay(existing, incoming)
                } else if last.displayName == nil {
                    last.displayName = run.displayName
                }
                compacted[compacted.count - 1] = last
            } else {
                compacted.append(run)
            }
        }
        return compacted
    }

    private static func firstNamedDisplay(within meters: Double, runs: [Run]) -> String? {
        for run in runs {
            if run.startDistanceAlong > meters { break }
            if run.isNamed, let name = run.displayName, !isGenericKey(run.compareKey) {
                return name
            }
        }
        return nil
    }

    private static func isPathLike(_ edge: GraphEdge) -> Bool {
        if edge.facilityType == .pavedTrail
            || edge.facilityType == .naturalTrail
            || edge.facilityType == .sidepath {
            return true
        }
        switch edge.osmClass {
        case .cycleway, .path, .track, .footway, .pedestrian:
            return true
        default:
            return false
        }
    }

    // MARK: - Turn classification

    private enum TurnClass {
        case straight, slight, turn, sharp, uTurn
    }

    private static func classify(_ absDegrees: Double) -> TurnClass {
        if absDegrees < straightDegrees { return .straight }
        if absDegrees < slightDegrees { return .slight }
        if absDegrees <= turnDegrees { return .turn }
        if absDegrees < uTurnDegrees { return .sharp }
        return .uTurn
    }

    private static func signedTurnDegrees(incoming: Double, outgoing: Double) -> Double {
        var delta = outgoing - incoming
        while delta <= -180 { delta += 360 }
        while delta > 180 { delta -= 360 }
        return delta
    }

    private static func cardinal(bearing: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        var normalized = bearing.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let index = Int(floor((normalized + 22.5) / 45.0)) % 8
        return names[index]
    }

    // MARK: - Instructions

    private static func departInstruction(bearing: Double, name: String?) -> String {
        let direction = cardinal(bearing: bearing)
        if let name, !name.isEmpty, name != "the path", name != "the street" {
            return "Head \(direction) on \(name)"
        }
        return "Head \(direction)"
    }

    private static func instruction(type: ManeuverType, streetName: String?) -> String {
        let onto: String
        if let streetName, !streetName.isEmpty {
            onto = " onto \(streetName)"
        } else {
            onto = ""
        }
        switch type {
        case .depart:
            return "Head north"
        case .continue:
            return "Continue\(onto.isEmpty ? "" : onto)"
        case .slightLeft:
            return "Bear left\(onto)"
        case .slightRight:
            return "Bear right\(onto)"
        case .left:
            return "Turn left\(onto)"
        case .right:
            return "Turn right\(onto)"
        case .sharpLeft:
            return "Sharp left\(onto)"
        case .sharpRight:
            return "Sharp right\(onto)"
        case .uTurn:
            return "Make a U-turn\(onto)"
        case .arrive:
            return "Arrive at destination"
        }
    }

    private static func stayOnInstruction(type: ManeuverType, streetName: String?) -> String {
        let stay: String
        if let streetName, !streetName.isEmpty {
            stay = " to stay on \(streetName)"
        } else {
            stay = ""
        }
        switch type {
        case .slightLeft:
            return "Bear left\(stay)"
        case .slightRight:
            return "Bear right\(stay)"
        case .left:
            return "Turn left\(stay)"
        case .right:
            return "Turn right\(stay)"
        case .sharpLeft:
            return "Sharp left\(stay)"
        case .sharpRight:
            return "Sharp right\(stay)"
        case .uTurn:
            return "Make a U-turn\(stay)"
        default:
            return instruction(type: type, streetName: streetName)
        }
    }

    // MARK: - Collapse / finalize

    private struct Draft {
        var type: ManeuverType
        var distanceAlong: Double
        var coordinate: CLLocationCoordinate2D
        var streetName: String?
        var instruction: String
        var turnAngleDegrees: Double?
    }

    private static func collapse(_ drafts: [Draft]) -> [Draft] {
        guard drafts.count > 2 else { return drafts }
        var result: [Draft] = [drafts[0]]
        let middle = drafts.dropFirst().dropLast()
        for draft in middle {
            if var last = result.last,
               last.type != .depart,
               abs(draft.distanceAlong - last.distanceAlong) < collapseMeters {
                if severity(draft.type) >= severity(last.type) {
                    last = draft
                }
                result[result.count - 1] = last
            } else {
                result.append(draft)
            }
        }
        if let arrive = drafts.last {
            result.append(arrive)
        }
        return result
    }

    private static func severity(_ type: ManeuverType) -> Int {
        switch type {
        case .depart, .arrive: return 0
        case .continue: return 1
        case .slightLeft, .slightRight: return 2
        case .left, .right: return 3
        case .sharpLeft, .sharpRight: return 4
        case .uTurn: return 5
        }
    }

    private static func finalize(_ drafts: [Draft]) -> [Maneuver] {
        guard !drafts.isEmpty else { return [] }
        var maneuvers: [Maneuver] = []
        for index in drafts.indices {
            let draft = drafts[index]
            let nextDistance: Double
            if index + 1 < drafts.count {
                nextDistance = max(0, drafts[index + 1].distanceAlong - draft.distanceAlong)
            } else {
                nextDistance = 0
            }
            maneuvers.append(
                Maneuver(
                    type: draft.type,
                    coordinate: draft.coordinate,
                    distanceAlongRoute: draft.distanceAlong,
                    distanceToNext: nextDistance,
                    streetName: draft.streetName,
                    instruction: draft.instruction,
                    turnAngleDegrees: draft.turnAngleDegrees
                )
            )
        }
        return maneuvers
    }
}

// MARK: - Polyline helpers

private struct PolylineIndex {
    let coordinates: [CLLocationCoordinate2D]
    let cumulative: [Double]
    let length: Double
    private let projection: LocalProjection

    init(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        let origin = coordinates[0]
        let projection = LocalProjection(
            originLatitude: origin.latitude,
            originLongitude: origin.longitude
        )
        self.projection = projection

        var cumulative: [Double] = [0]
        var total = 0.0
        let locals = coordinates.map { projection.toLocal($0) }
        for i in 1..<locals.count {
            total += locals[i - 1].distance(to: locals[i])
            cumulative.append(total)
        }
        self.cumulative = cumulative
        self.length = total
    }

    func coordinate(at distance: Double) -> CLLocationCoordinate2D? {
        guard coordinates.count >= 2 else { return coordinates.first }
        let target = min(max(0, distance), length)
        if target <= 0 { return coordinates.first }
        if target >= length { return coordinates.last }

        var index = 1
        while index < cumulative.count, cumulative[index] < target {
            index += 1
        }
        let i = min(max(1, index), coordinates.count - 1)
        let d0 = cumulative[i - 1]
        let d1 = cumulative[i]
        let seg = max(d1 - d0, 1e-9)
        let t = (target - d0) / seg
        let a = coordinates[i - 1]
        let b = coordinates[i]
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// Bearing over `spanMeters` of non-synthetic geometry from `fromDistance`.
    func bearingSkippingSynthetic(
        fromDistance: Double,
        towardIncreasing: Bool,
        spanMeters: Double,
        edgeSpans: [ManeuverBuilder.EdgeSpan]
    ) -> Double? {
        let sampleStep = 1.0
        var remaining = spanMeters
        var cursor = min(max(0, fromDistance), length)
        var near = cursor
        var far = cursor

        let nudge = towardIncreasing ? sampleStep : -sampleStep
        var probe = cursor
        var guardCount = 0
        while isSyntheticInterior(probe, spans: edgeSpans), guardCount < 10_000 {
            probe += nudge
            if probe < 0 || probe > length { break }
            guardCount += 1
        }
        if probe >= 0, probe <= length {
            cursor = probe
            near = cursor
            far = cursor
        }

        while remaining > 1e-6 {
            let next = towardIncreasing
                ? min(length, cursor + sampleStep)
                : max(0, cursor - sampleStep)
            if abs(next - cursor) < 1e-9 { break }

            let mid = (cursor + next) * 0.5
            if isSyntheticInterior(mid, spans: edgeSpans) {
                cursor = next
                continue
            }

            let step = abs(next - cursor)
            remaining -= step
            far = next
            cursor = next
            if (towardIncreasing && cursor >= length) || (!towardIncreasing && cursor <= 0) {
                break
            }
        }

        let from = towardIncreasing ? near : far
        let to = towardIncreasing ? far : near
        return bearing(fromDistance: from, toDistance: to)
    }

    private func isSyntheticInterior(_ distance: Double, spans: [ManeuverBuilder.EdgeSpan]) -> Bool {
        let d = min(max(0, distance), length)
        for span in spans where span.isSynthetic {
            if d > span.start + 1e-6, d < span.end - 1e-6 {
                return true
            }
        }
        return false
    }

    func bearing(fromDistance: Double, toDistance: Double) -> Double? {
        guard let a = coordinate(at: fromDistance), let b = coordinate(at: toDistance) else {
            return nil
        }
        let la = projection.toLocal(a)
        let lb = projection.toLocal(b)
        let dx = lb.x - la.x
        let dy = lb.y - la.y
        if abs(dx) < 1e-9, abs(dy) < 1e-9 { return nil }
        var degrees = atan2(dx, dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}
