import SwiftUI
import MapKit

struct RideSummaryView: View {
    let session: RideSession
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    RouteMapView(coordinates: session.coordinates)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)

                    StatsGrid(session: session)
                        .padding(.horizontal)

                    CaloriesCard(calories: session.estimatedCalories)
                        .padding(.horizontal)

                    Text("Calories estimated using a 154 lb / 70 kg rider weight.")
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
                    Button("Done", action: onDone)
                        .bold()
                }
            }
        }
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
