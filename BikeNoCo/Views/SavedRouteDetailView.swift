import SwiftUI
import SwiftData
import Charts
import MapKit
import CoreLocation

struct SavedRouteDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var route: SavedRoute
    let graph: BikeNetworkGraph?
    let onRide: () -> Void

    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var showDeleteConfirm = false
    @State private var previewCoordinates: [CLLocationCoordinate2D] = []

    private var orderedRides: [SavedRide] {
        route.rides.sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RoutePreviewMap(coordinates: previewCoordinates)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f mi", route.distanceMiles))
                            .font(.title2.bold())
                        Text(String(format: "%.0f%% low-stress", route.lowStressShare * 100))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(route.timesRidden)× ridden")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(action: onRide) {
                    Label("Ride this route", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if !orderedRides.isEmpty {
                    Text("History")
                        .font(.headline)
                    RouteHistoryChart(rides: orderedRides)
                        .frame(height: 180)

                    ForEach(orderedRides, id: \.id) { ride in
                        HStack {
                            Text(ride.startDate, format: .dateTime.month().day().year())
                            Spacer()
                            Text(formatDuration(ride.movingDuration))
                                .monospacedDigit()
                            Text(String(format: "%.1f mph", ride.avgSpeedMPH))
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            if route.isPersonalBest(ride) {
                                Image(systemName: "trophy.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                        }
                        .font(.subheadline)
                    }
                }

                HStack {
                    Button("Rename") {
                        renameDraft = route.name
                        showRename = true
                    }
                    .buttonStyle(.bordered)

                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshPreview() }
        .alert("Rename route", isPresented: $showRename) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                route.name = name
                try? modelContext.save()
            }
        }
        .alert("Delete this route?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                for ride in route.rides {
                    ride.route = nil
                }
                modelContext.delete(route)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your rides stay in My Rides; they are just unlinked from this route.")
        }
    }

    private func refreshPreview() {
        let waypoints = route.waypoints
        guard waypoints.count >= 2 else {
            previewCoordinates = waypoints
            return
        }
        if let graph {
            switch RouteFinder.routeThrough(waypoints: waypoints, graph: graph) {
            case .success(let planned):
                previewCoordinates = planned.coordinates
            case .failure:
                previewCoordinates = waypoints
            }
        } else {
            previewCoordinates = waypoints
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct RouteHistoryChart: View {
    let rides: [SavedRide]

    private var bestID: UUID? {
        rides.min(by: { $0.movingDuration < $1.movingDuration })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(Array(rides.enumerated()), id: \.element.id) { index, ride in
                    LineMark(
                        x: .value("Ride", index + 1),
                        y: .value("Minutes", ride.movingDuration / 60)
                    )
                    PointMark(
                        x: .value("Ride", index + 1),
                        y: .value("Minutes", ride.movingDuration / 60)
                    )
                    .foregroundStyle(ride.id == bestID ? Color.orange : Color.accentColor)
                    .symbolSize(ride.id == bestID ? 80 : 40)
                }
            }
            .chartYAxisLabel("Moving time (min)")
            .frame(height: 100)

            Chart {
                ForEach(Array(rides.enumerated()), id: \.element.id) { index, ride in
                    BarMark(
                        x: .value("Ride", index + 1),
                        y: .value("mph", ride.avgSpeedMPH)
                    )
                    .foregroundStyle(ride.id == bestID ? Color.orange.opacity(0.8) : Color.green.opacity(0.7))
                }
            }
            .chartYAxisLabel("Avg speed (mph)")
            .frame(height: 80)
        }
    }
}

private struct RoutePreviewMap: UIViewRepresentable {
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
        map.delegate = context.coordinator
        guard coordinates.count > 1 else { return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(polyline, level: .aboveRoads)

        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.3, 0.002),
                longitudeDelta: max((maxLon - minLon) * 1.3, 0.002)
            )
        )
        map.setRegion(region, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 4
            renderer.lineCap = .round
            return renderer
        }
    }
}
