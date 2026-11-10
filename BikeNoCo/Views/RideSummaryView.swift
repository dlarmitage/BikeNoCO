import SwiftUI
import MapKit

struct RideSummaryView: View {
    let session: RideSession
    var isSaved: Bool
    var needsManualSave: Bool
    var routeName: String?
    var rideOrdinal: Int?
    var isPersonalBest: Bool
    var suggestedRouteName: String
    var riderWeightPounds: Double
    var isAlreadyOnMyRoutes: Bool
    /// When false, content is pushed inside an existing `NavigationStack` (no Done, uses back).
    var embedsNavigationStack: Bool = true
    var showsDoneButton: Bool = true
    let onDone: () -> Void
    var onSave: (() -> Void)?
    var onDelete: (() -> Void)?
    var onAddToMyRoutes: ((String) -> Void)?

    @State private var showDeleteConfirm = false
    @State private var showNamePrompt = false
    @State private var routeNameDraft = ""
    @State private var isCreatingRoute = false

    var body: some View {
        if embedsNavigationStack {
            NavigationStack { summaryBody }
        } else {
            summaryBody
        }
    }

    private var summaryBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                RouteMapView(coordinates: session.coordinates)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                if let routeName, let rideOrdinal {
                    RouteHistoryBanner(
                        routeName: routeName,
                        ordinal: rideOrdinal,
                        isPersonalBest: isPersonalBest
                    )
                    .padding(.horizontal)
                }

                StatsGrid(session: session)
                    .padding(.horizontal)

                CaloriesCard(calories: session.estimatedCalories)
                    .padding(.horizontal)

                Text(String(format: "Calories estimated using a %.0f lb rider weight.", riderWeightPounds))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("Ride Summary")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if onAddToMyRoutes != nil {
                        Button {
                            if isAlreadyOnMyRoutes { return }
                            routeNameDraft = suggestedRouteName
                            showNamePrompt = true
                        } label: {
                            Image(systemName: isAlreadyOnMyRoutes ? "star.fill" : "star")
                                .foregroundStyle(isAlreadyOnMyRoutes ? Color.orange : Color.accentColor)
                        }
                        .disabled(isCreatingRoute || isAlreadyOnMyRoutes)
                        .accessibilityLabel(
                            isAlreadyOnMyRoutes ? "On My Routes" : "Add to My Routes"
                        )
                    }

                    if showsDoneButton {
                        Button("Done", action: onDone)
                            .bold()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if needsManualSave || isSaved {
                VStack(spacing: 10) {
                    if needsManualSave, let onSave {
                        Button {
                            onSave()
                        } label: {
                            Label("Save this ride", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if isSaved, let onDelete {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete ride", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
        .alert("Delete this ride?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the ride from My Rides.")
        }
        .alert("Add to My Routes", isPresented: $showNamePrompt) {
            TextField("Route name", text: $routeNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = routeNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                isCreatingRoute = true
                onAddToMyRoutes?(name)
            }
        } message: {
            Text("Name this route so you can ride it again and compare times.")
        }
        .onAppear {
            routeNameDraft = suggestedRouteName
        }
        .onChange(of: isAlreadyOnMyRoutes) { _, starred in
            if starred { isCreatingRoute = false }
        }
        .onChange(of: suggestedRouteName) { _, newName in
            if !showNamePrompt {
                routeNameDraft = newName
            }
        }
    }
}

private struct RouteHistoryBanner: View {
    let routeName: String
    let ordinal: Int
    let isPersonalBest: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .foregroundStyle(.tint)
            Text("\(ordinal.ordinalLabel) time on \(routeName)")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            if isPersonalBest {
                Label("Personal best", systemImage: "trophy.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension Int {
    var ordinalLabel: String {
        let mod100 = self % 100
        let mod10 = self % 10
        let suffix: String
        if (11...13).contains(mod100) {
            suffix = "th"
        } else {
            switch mod10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(self)\(suffix)"
    }
}

// MARK: - Route mini-map

private struct RouteMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = false
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        guard coordinates.count > 1 else { return }

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(polyline, level: .aboveRoads)

        let region = MKCoordinateRegion(coordinates: coordinates)
        map.setRegion(region.padded(by: 0.15), animated: false)

        map.delegate = context.coordinator
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = UIColor.systemBlue
            r.lineWidth = 4
            r.lineCap = .round
            return r
        }
    }
}

private extension MKCoordinateRegion {
    init(coordinates: [CLLocationCoordinate2D]) {
        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        self.init(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: maxLat - minLat, longitudeDelta: maxLon - minLon)
        )
    }

    func padded(by fraction: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(span.latitudeDelta * (1 + fraction), 0.002),
                longitudeDelta: max(span.longitudeDelta * (1 + fraction), 0.002)
            )
        )
    }
}

// MARK: - Stats grid

private struct StatsGrid: View {
    let session: RideSession

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(icon: "figure.outdoor.cycle", label: "Distance", value: String(format: "%.2f", session.distanceMiles), unit: "mi")
                StatCard(icon: "clock", label: "Duration", value: formatDuration(session.duration), unit: "")
            }
            HStack(spacing: 12) {
                StatCard(icon: "speedometer", label: "Avg Speed", value: String(format: "%.1f", session.avgSpeedMPH), unit: "mph")
                StatCard(icon: "hare", label: "Max Speed", value: String(format: "%.1f", session.maxSpeedMPH), unit: "mph")
            }
            HStack(spacing: 12) {
                StatCard(icon: "arrow.up.right", label: "Elevation Gain", value: String(format: "%.0f", session.elevationGainFeet), unit: "ft", tint: .green)
                StatCard(icon: "arrow.down.right", label: "Elevation Loss", value: String(format: "%.0f", session.elevationLossFeet), unit: "ft", tint: .orange)
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.bold())
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CaloriesCard: View {
    let calories: Double

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Estimated Calories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", calories))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("kcal")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
