import SwiftUI
import MapKit

struct BikeMapView: UIViewRepresentable {
    let routes: [BikeRoute]
    let activeRoute: BikeRoute?
    @Binding var selectedRoute: BikeRoute?
    let mapType: MKMapType
    @Binding var trackingMode: MKUserTrackingMode
    @Binding var focusRouteID: UUID?

    private static let fortCollinsRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.5853, longitude: -105.0844),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.06)
    )
    private static let preferredSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = true
        mapView.setRegion(Self.fortCollinsRegion, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let c = context.coordinator

        if mapView.mapType != mapType { mapView.mapType = mapType }
        if mapView.userTrackingMode != trackingMode {
            mapView.setUserTrackingMode(trackingMode, animated: true)
        }

        let routeIDs = Set(routes.map { $0.id })
        let routesChanged = routeIDs != c.lastRouteIDs
        let activeChanged = activeRoute?.id != c.lastActiveID

        // ── Rebuild infrastructure multi-polylines when the route set changes ──
        // One MKMultiPolyline per FacilityType = ~10 overlays total instead of ~5000.
        if routesChanged {
            mapView.removeOverlays(Array(c.multiPolylines.values))
            c.multiPolylines = [:]
            c.lastRouteIDs = routeIDs

            var grouped: [FacilityType: [MKPolyline]] = [:]
            for route in routes {
                for path in route.paths where !path.isEmpty {
                    grouped[route.facilityType, default: []]
                        .append(MKPolyline(coordinates: path, count: path.count))
                }
            }
            for (type, lines) in grouped {
                let multi = MKMultiPolyline(lines)
                c.multiPolylines[type] = multi
            }
            mapView.addOverlays(Array(c.multiPolylines.values), level: .aboveRoads)
        }

        // ── Handle active route overlay and infra dimming ──
        if activeChanged || routesChanged {
            c.lastActiveID = activeRoute?.id
            c.hasActiveRoute = activeRoute != nil

            // Swap the single active-route polyline (one overlay)
            if let old = c.activePolyline { mapView.removeOverlay(old) }
            c.activePolyline = nil
            if let route = activeRoute {
                let coords = route.paths.flatMap { $0 }
                if !coords.isEmpty {
                    let p = MKPolyline(coordinates: coords, count: coords.count)
                    c.activePolyline = p
                    mapView.addOverlay(p, level: .aboveLabels)
                }
            }

            // Force infra renderer recreation with the updated dim state.
            // Re-adding ~10 MKMultiPolyline objects is instant.
            if !routesChanged {
                let current = Array(c.multiPolylines.values)
                mapView.removeOverlays(current)
                mapView.addOverlays(current, level: .aboveRoads)
            }
        }

        // ── Zoom to active route ──
        if let id = focusRouteID, id != c.lastFocusedID {
            c.lastFocusedID = id
            let target = (activeRoute?.id == id ? activeRoute : routes.first { $0.id == id })
            if let coords = target?.paths.flatMap({ $0 }),
               let region = MKCoordinateRegion(fitting: coords, paddingFactor: 1.35) {
                mapView.setRegion(region, animated: true)
            }
            DispatchQueue.main.async { self.focusRouteID = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: BikeMapView
        private var hasZoomedToUser = false

        // Infrastructure: one MKMultiPolyline per FacilityType
        var multiPolylines: [FacilityType: MKMultiPolyline] = [:]
        var lastRouteIDs: Set<UUID> = []

        // Active suggested-ride overlay
        var activePolyline: MKPolyline?
        var lastActiveID: UUID?
        var hasActiveRoute = false

        var lastFocusedID: UUID?

        init(parent: BikeMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !hasZoomedToUser else { return }
            hasZoomedToUser = true
            mapView.setRegion(
                MKCoordinateRegion(center: userLocation.coordinate, span: BikeMapView.preferredSpan),
                animated: true
            )
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            DispatchQueue.main.async { self.parent.trackingMode = mode }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Active suggested-ride: dashed red polyline
            if let polyline = overlay as? MKPolyline, overlay === activePolyline {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = FacilityType.recommendedRide.color
                r.lineWidth = FacilityType.recommendedRide.lineWidth
                r.lineCap = .round
                r.lineJoin = .round
                r.lineDashPattern = [NSNumber(value: 18), NSNumber(value: 8)]
                return r
            }

            // Infrastructure: one renderer per FacilityType
            if let multi = overlay as? MKMultiPolyline,
               let type = multiPolylines.first(where: { $0.value === multi })?.key {
                let r = MKMultiPolylineRenderer(multiPolyline: multi)
                r.strokeColor = hasActiveRoute ? .clear : type.color
                r.lineWidth = type.lineWidth
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let tapPt = MKMapPoint(mapView.convert(gesture.location(in: mapView),
                                                   toCoordinateFrom: mapView))
            let tolerance = metersPerPixel(in: mapView) * 12

            // When a suggested ride is active only allow tapping it
            let candidates: [BikeRoute] = hasActiveRoute
                ? (parent.activeRoute.map { [$0] } ?? [])
                : parent.routes

            var closest: BikeRoute?
            var closestDist = Double.infinity
            for route in candidates {
                for path in route.paths {
                    let pts = path.map { MKMapPoint($0) }
                    for i in 0..<(pts.count - 1) {
                        let d = segmentDistance(tapPt, pts[i], pts[i + 1])
                        if d < tolerance && d < closestDist {
                            closest = route
                            closestDist = d
                        }
                    }
                }
            }
            DispatchQueue.main.async { self.parent.selectedRoute = closest }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private func metersPerPixel(in mapView: MKMapView) -> Double {
            let r = mapView.region
            let mpp = 111_319.9 * cos(r.center.latitude * .pi / 180)
            return (r.span.longitudeDelta / Double(mapView.bounds.width)) * mpp
        }

        private func segmentDistance(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx*dx + dy*dy
            guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x)*dx + (p.y - a.y)*dy) / len2))
            return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
        }
    }
}

private extension MKCoordinateRegion {
    init?(fitting coords: [CLLocationCoordinate2D], paddingFactor: Double = 1.3) {
        guard coords.count >= 2 else { return nil }
        let lats = coords.map { $0.latitude }, lons = coords.map { $0.longitude }
        let latDelta = max((lats.max()! - lats.min()!) * paddingFactor, 0.01)
        let lonDelta = max((lons.max()! - lons.min()!) * paddingFactor, 0.01)
        self.init(
            center: CLLocationCoordinate2D(
                latitude: (lats.min()! + lats.max()!) / 2,
                longitude: (lons.min()! + lons.max()!) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}
