import SwiftUI
import SwiftData
import Charts
import CoreLocation

struct RidesSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedRide.startDate, order: .reverse) private var rides: [SavedRide]
    @Query(sort: \SavedRoute.createdDate, order: .reverse) private var routes: [SavedRoute]

    let graph: BikeNetworkGraph?
    /// Loads the saved route onto the map. Caller should dismiss this sheet first
    /// (or we dismiss here) — do not present another sheet from this callback.
    let onRideThisRoute: (SavedRoute) -> Void
    var onExportGPX: ((RideSession) -> Void)?
    var onMatchQuality: ((Double) -> Void)?

    @State private var tab = SheetTab.rides
    @State private var ridePendingDelete: SavedRide?
    @State private var selectedRideID: UUID?
    @State private var selectedRouteID: UUID?
    @State private var suggestedNameByRideID: [UUID: String] = [:]

    private enum SheetTab: String, CaseIterable, Identifiable {
        case rides = "My Rides"
        case routes = "My Routes"
        var id: String { rawValue }
    }

    private var rideStore: RideStore { RideStore(modelContext: modelContext) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $tab) {
                    ForEach(SheetTab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch tab {
                    case .rides:
                        MyRidesTab(
                            rides: rides,
                            onSelect: { selectedRideID = $0.id },
                            onDelete: { ridePendingDelete = $0 },
                            onExportGPX: onExportGPX
                        )
                    case .routes:
                        MyRoutesTab(
                            routes: routes,
                            onSelect: { selectedRouteID = $0.id }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Rides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Delete this ride?",
                isPresented: Binding(
                    get: { ridePendingDelete != nil },
                    set: { if !$0 { ridePendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let ride = ridePendingDelete {
                        modelContext.delete(ride)
                        try? modelContext.save()
                        if selectedRideID == ride.id {
                            selectedRideID = nil
                        }
                    }
                    ridePendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    ridePendingDelete = nil
                }
            } message: {
                Text("This permanently removes the ride from My Rides.")
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedRideID != nil },
                set: { if !$0 { selectedRideID = nil } }
            )) {
                if let id = selectedRideID, let ride = rides.first(where: { $0.id == id }) {
                    storedRideSummary(for: ride)
                } else {
                    ContentUnavailableView("Ride not found", systemImage: "figure.outdoor.cycle")
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedRouteID != nil },
                set: { if !$0 { selectedRouteID = nil } }
            )) {
                if let id = selectedRouteID, let route = routes.first(where: { $0.id == id }) {
                    SavedRouteDetailView(
                        route: route,
                        graph: graph,
                        onRide: {
                            // Dismiss first so we don't stack sheet transitions.
                            let saved = route
                            dismiss()
                            DispatchQueue.main.async {
                                onRideThisRoute(saved)
                            }
                        }
                    )
                } else {
                    ContentUnavailableView("Route not found", systemImage: "star")
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func storedRideSummary(for ride: SavedRide) -> some View {
        let session = (try? ride.toSession()) ?? RideSession(
            id: ride.id,
            startDate: ride.startDate,
            endDate: ride.endDate,
            trackPoints: [],
            distanceMeters: ride.distanceMeters,
            avgSpeedMPS: ride.avgSpeedMPS,
            maxSpeedMPS: ride.maxSpeedMPS,
            elevationGainMeters: ride.elevationGainMeters,
            elevationLossMeters: ride.elevationLossMeters,
            estimatedCalories: ride.estimatedCalories,
            movingDuration: ride.movingDuration
        )
        let route = ride.route
        let suggested = suggestedNameByRideID[ride.id]
            ?? suggestedName(for: session)

        RideSummaryView(
            session: session,
            isSaved: true,
            needsManualSave: false,
            routeName: route?.name,
            rideOrdinal: route.flatMap { $0.rideOrdinal(for: ride) },
            isPersonalBest: route.map { $0.isPersonalBest(ride) } ?? false,
            suggestedRouteName: suggested,
            riderWeightPounds: RiderSettings.weightPounds,
            isAlreadyOnMyRoutes: route != nil,
            embedsNavigationStack: false,
            showsDoneButton: false,
            onDone: { selectedRideID = nil },
            onSave: nil,
            onDelete: {
                try? rideStore.deleteRide(ride)
                selectedRideID = nil
            },
            onAddToMyRoutes: { name in
                starRide(session: session, name: name)
            }
        )
        .onAppear {
            if suggestedNameByRideID[ride.id] == nil {
                suggestedNameByRideID[ride.id] = suggested
            }
        }
    }

    private func starRide(session: RideSession, name: String) {
        guard let graph else {
            NSLog("[BikeNoCo] Add to My Routes failed: graph not ready")
            return
        }
        do {
            let created = try rideStore.createRoute(from: session, name: name, graph: graph)
            onMatchQuality?(created.matchQuality)
            #if DEBUG
            NSLog(
                "[BikeNoCo] Add to My Routes \"%@\" match quality %.1f%%",
                name,
                created.matchQuality * 100
            )
            #endif
        } catch {
            NSLog("[BikeNoCo] Add to My Routes failed: %@", error.localizedDescription)
        }
    }

    private func suggestedName(for session: RideSession) -> String {
        guard let graph, session.coordinates.count >= 2 else { return "My Route" }
        switch TrackToRouteConverter.convert(track: session.coordinates, graph: graph) {
        case .success(let result):
            return TrackToRouteConverter.suggestedName(for: result.plannedRoute)
        case .failure:
            return "My Route"
        }
    }
}

// MARK: - My Rides

private struct MyRidesTab: View {
    let rides: [SavedRide]
    let onSelect: (SavedRide) -> Void
    let onDelete: (SavedRide) -> Void
    var onExportGPX: ((RideSession) -> Void)?

    private var grouped: [(String, [SavedRide])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let dict = Dictionary(grouping: rides) { formatter.string(from: $0.startDate) }
        return dict.keys.sorted { lhs, rhs in
            guard let a = dict[lhs]?.first?.startDate, let b = dict[rhs]?.first?.startDate else {
                return lhs > rhs
            }
            return a > b
        }.map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        if rides.isEmpty {
            ContentUnavailableView(
                "No rides yet",
                systemImage: "figure.outdoor.cycle",
                description: Text("Finished rides appear here automatically.")
            )
        } else {
            List {
                Section {
                    RideTotalsHeader(rides: rides)
                    WeeklyDistanceChart(rides: rides)
                        .frame(height: 140)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                ForEach(grouped, id: \.0) { month, monthRides in
                    Section(month) {
                        ForEach(monthRides, id: \.id) { ride in
                            Button {
                                onSelect(ride)
                            } label: {
                                RideRow(ride: ride)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    onDelete(ride)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                #if DEBUG
                                if let onExportGPX {
                                    Button {
                                        if let session = try? ride.toSession() {
                                            onExportGPX(session)
                                        }
                                    } label: {
                                        Label("GPX", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.indigo)
                                }
                                #endif
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct RideTotalsHeader: View {
    let rides: [SavedRide]

    private var calendar: Calendar { .current }

    var body: some View {
        let now = Date()
        let week = totals(in: calendar.dateInterval(of: .weekOfYear, for: now))
        let month = totals(in: calendar.dateInterval(of: .month, for: now))
        let year = totals(in: calendar.dateInterval(of: .year, for: now))

        VStack(alignment: .leading, spacing: 10) {
            Text("Totals")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                TotalChip(title: "Week", distanceMiles: week.distance / 1609.344, moving: week.moving)
                TotalChip(title: "Month", distanceMiles: month.distance / 1609.344, moving: month.moving)
                TotalChip(title: "Year", distanceMiles: year.distance / 1609.344, moving: year.moving)
            }
        }
        .padding(.vertical, 4)
    }

    private func totals(in interval: DateInterval?) -> (distance: Double, moving: TimeInterval, elev: Double) {
        guard let interval else { return (0, 0, 0) }
        var distance = 0.0
        var moving = 0.0
        var elev = 0.0
        for ride in rides where interval.contains(ride.startDate) {
            distance += ride.distanceMeters
            moving += ride.movingDuration
            elev += ride.elevationGainMeters
        }
        return (distance, moving, elev)
    }
}

private struct TotalChip: View {
    let title: String
    let distanceMiles: Double
    let moving: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f mi", distanceMiles))
                .font(.subheadline.bold())
            Text(formatDuration(moving))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        return h > 0 ? String(format: "%dh %dm", h, m) : String(format: "%dm", m)
    }
}

private struct WeeklyDistanceChart: View {
    let rides: [SavedRide]

    private struct WeekBucket: Identifiable {
        let weekStart: Date
        let miles: Double
        var id: Date { weekStart }
    }

    private var buckets: [WeekBucket] {
        let calendar = Calendar.current
        let now = Date()
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var result: [WeekBucket] = []
        for offset in stride(from: 11, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else {
                continue
            }
            let interval = DateInterval(start: start, end: end)
            let meters = rides
                .filter { interval.contains($0.startDate) }
                .reduce(0.0) { $0 + $1.distanceMeters }
            result.append(WeekBucket(weekStart: start, miles: meters / 1609.344))
        }
        return result
    }

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                y: .value("Miles", bucket.miles)
            )
            .foregroundStyle(Color.accentColor.gradient)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartYAxisLabel("mi", position: .leading)
    }
}

private struct RideRow: View {
    let ride: SavedRide

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.startDate, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 12) {
                    Text(String(format: "%.1f mi", ride.distanceMiles))
                    Text(formatDuration(ride.movingDuration))
                    if let route = ride.route {
                        Text(route.name)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        return h > 0 ? String(format: "%d:%02d", h, m) : String(format: "%dm", m)
    }
}

// MARK: - My Routes

private struct MyRoutesTab: View {
    let routes: [SavedRoute]
    let onSelect: (SavedRoute) -> Void

    var body: some View {
        if routes.isEmpty {
            ContentUnavailableView(
                "No saved routes",
                systemImage: "star",
                description: Text("Star a finished ride to add it to My Routes.")
            )
        } else {
            List {
                ForEach(routes, id: \.id) { route in
                    Button {
                        onSelect(route)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            HStack(spacing: 12) {
                                Text(String(format: "%.1f mi", route.distanceMiles))
                                Text("\(route.timesRidden)× ridden")
                                if let best = route.bestMovingDuration {
                                    Text("Best \(formatDuration(best))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
