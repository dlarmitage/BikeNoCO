import SwiftUI
import MapKit

struct BikeMapView: UIViewRepresentable {
    let routes: [BikeRoute]
    let activeRoute: BikeRoute?
    let plannedRoute: PlannedRoute?
    let routeDestination: CLLocationCoordinate2D?
    /// When navigating, the yet-to-ride portion of the planned route (clears behind the rider).
    var remainingRouteCoordinates: [CLLocationCoordinate2D]? = nil
    /// Live fix from `LocationProvider` (hardware or Simulate Ride). Drives the blue puck
    /// because MapKit's built-in dot ignores our shared location stream.
    var userPuckLocation: CLLocation? = nil
    @Binding var selectedRoute: BikeRoute?
    @Binding var userCoordinate: CLLocationCoordinate2D?
    let mapType: MKMapType
    @Binding var trackingMode: MKUserTrackingMode
    @Binding var focusRouteID: UUID?
    @Binding var focusCoordinate: CLLocationCoordinate2D?
    @Binding var cameraCommand: MapCameraCommand?
    var onLongPressDestination: ((CLLocationCoordinate2D) -> Void)?

    static let fortCollinsRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.5853, longitude: -105.0844),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.06)
    )
    private static let preferredSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        // Compass appears when the map is rotated; tap it to restore north-up.
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.setRegion(Self.fortCollinsRegion, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        mapView.addGestureRecognizer(longPress)

        // Mouse / trackpad scroll wheel → zoom (Simulator + pointer devices).
        // MapKit does not zoom on scroll by default.
        let scrollZoom = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleScrollZoom(_:))
        )
        scrollZoom.delegate = context.coordinator
        scrollZoom.allowedScrollTypesMask = .continuous
        scrollZoom.maximumNumberOfTouches = 0
        mapView.addGestureRecognizer(scrollZoom)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self

        if mapView.mapType != mapType { mapView.mapType = mapType }

        let usingUserPuck = userPuckLocation != nil
        // Prefer our puck (shared LocationProvider) over MapKit's independent blue dot.
        if mapView.showsUserLocation == usingUserPuck {
            mapView.showsUserLocation = !usingUserPuck
        }

        // MapKit tracking only follows its own blue dot — drive the camera ourselves for our puck.
        if usingUserPuck {
            if mapView.userTrackingMode != .none {
                mapView.setUserTrackingMode(.none, animated: false)
            }
        } else if mapView.userTrackingMode != trackingMode {
            mapView.setUserTrackingMode(trackingMode, animated: true)
        }

        if let command = cameraCommand {
            switch command {
            case .zoomIn:
                Self.zoom(mapView, factor: 0.5)
            case .zoomOut:
                Self.zoom(mapView, factor: 2.0)
            case .fortCollins:
                mapView.setRegion(Self.fortCollinsRegion, animated: true)
            case .northUp:
                Self.applyNorthUpCamera(on: mapView, center: userPuckLocation?.coordinate)
            }
            DispatchQueue.main.async { self.cameraCommand = nil }
        }

        // Entering north-up follow should reorient immediately (don't wait for movement).
        if trackingMode == .follow, c.lastAppliedTrackingMode != .follow {
            Self.applyNorthUpCamera(on: mapView, center: userPuckLocation?.coordinate)
        }
        c.lastAppliedTrackingMode = trackingMode

        let routeIDs = Set(routes.map { $0.id })
        let routesChanged = routeIDs != c.lastRouteIDs
        let activeChanged = activeRoute?.id != c.lastActiveID
        let displayPlannedCoordinates = remainingRouteCoordinates
            ?? plannedRoute?.coordinates
        let plannedChanged = !Self.sameCoordinates(displayPlannedCoordinates, c.lastPlannedCoordinates)
            || !Self.sameCoordinate(routeDestination, c.lastDestination)

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

        // ── Planned route overlay + destination pin ──
        // While navigating, `remainingRouteCoordinates` trims the trail behind the rider.
        if plannedChanged {
            c.lastPlannedCoordinates = displayPlannedCoordinates
            c.lastDestination = routeDestination

            if let old = c.plannedPolyline { mapView.removeOverlay(old) }
            c.plannedPolyline = nil
            if let coords = displayPlannedCoordinates, coords.count >= 2 {
                let line = MKPolyline(coordinates: coords, count: coords.count)
                c.plannedPolyline = line
                mapView.addOverlay(line, level: .aboveLabels)
            }

            if let pin = c.destinationAnnotation {
                mapView.removeAnnotation(pin)
                c.destinationAnnotation = nil
            }
            if let destination = routeDestination {
                let annotation = MKPointAnnotation()
                annotation.coordinate = destination
                annotation.title = "Destination"
                c.destinationAnnotation = annotation
                mapView.addAnnotation(annotation)
            }
        }

        // ── User puck from LocationProvider (hardware GPS or Simulate Ride) ──
        c.updateUserPuck(on: mapView, location: userPuckLocation, trackingMode: trackingMode)

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

        // ── Center on a maneuver / arbitrary coordinate ──
        if let coordinate = focusCoordinate {
            let region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.focusCoordinate = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Scale the current region span by `factor` (< 1 zooms in, > 1 zooms out).
    static func zoom(_ mapView: MKMapView, factor: Double) {
        var region = mapView.region
        let lat = min(max(region.span.latitudeDelta * factor, 0.0004), 60)
        let lon = min(max(region.span.longitudeDelta * factor, 0.0004), 60)
        region.span = MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lon)
        mapView.setRegion(region, animated: true)
    }

    /// Flat, north-up camera at the current (or given) center, preserving zoom distance.
    static func applyNorthUpCamera(on mapView: MKMapView, center: CLLocationCoordinate2D?) {
        let coordinate = center ?? mapView.centerCoordinate
        let distance = mapView.camera.centerCoordinateDistance
        let camera = MKMapCamera(
            lookingAtCenter: coordinate,
            fromDistance: distance > 1 ? distance : 1_000,
            pitch: 0,
            heading: 0
        )
        mapView.setCamera(camera, animated: true)
    }

    /// True while the rider is pinching/panning/rotating — skip programmatic camera fights.
    static func isActivelyGesturing(_ mapView: MKMapView) -> Bool {
        guard let recognizers = mapView.gestureRecognizers else { return false }
        return recognizers.contains { $0.state == .began || $0.state == .changed }
    }

    private static func sameCoordinate(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
        default: return false
        }
    }

    private static func sameCoordinates(_ a: [CLLocationCoordinate2D]?, _ b: [CLLocationCoordinate2D]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            guard a.count == b.count else { return false }
            for i in a.indices {
                if abs(a[i].latitude - b[i].latitude) > 1e-9
                    || abs(a[i].longitude - b[i].longitude) > 1e-9 {
                    return false
                }
            }
            return true
        default: return false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: BikeMapView
        private var hasZoomedToUser = false
        var lastAppliedTrackingMode: MKUserTrackingMode = .none

        // Infrastructure: one MKMultiPolyline per FacilityType
        var multiPolylines: [FacilityType: MKMultiPolyline] = [:]
        var lastRouteIDs: Set<UUID> = []

        // Active suggested-ride overlay
        var activePolyline: MKPolyline?
        var lastActiveID: UUID?
        var hasActiveRoute = false

        // Planned point-to-point route
        var plannedPolyline: MKPolyline?
        var lastPlannedCoordinates: [CLLocationCoordinate2D]?
        var destinationAnnotation: MKPointAnnotation?
        var lastDestination: CLLocationCoordinate2D?

        // LocationProvider-driven puck (replaces MapKit blue dot once we have a fix).
        var userPuck: UserLocationAnnotation?
        private var lastPuckCoordinate: CLLocationCoordinate2D?

        var lastFocusedID: UUID?

        init(parent: BikeMapView) { self.parent = parent }

        func updateUserPuck(
            on mapView: MKMapView,
            location: CLLocation?,
            trackingMode: MKUserTrackingMode
        ) {
            guard let location else {
                if let puck = userPuck {
                    mapView.removeAnnotation(puck)
                    userPuck = nil
                }
                lastPuckCoordinate = nil
                return
            }

            let coordinate = location.coordinate
            if let puck = userPuck {
                puck.coordinate = coordinate
                if location.course >= 0 {
                    puck.course = location.course
                }
                if let view = mapView.view(for: puck) as? UserLocationAnnotationView {
                    view.update(from: puck)
                }
            } else {
                let puck = UserLocationAnnotation(coordinate: coordinate, course: location.course)
                userPuck = puck
                mapView.addAnnotation(puck)
            }

            DispatchQueue.main.async {
                self.parent.userCoordinate = coordinate
            }

            // First NoCo fix: center the startup map on the rider.
            if !hasZoomedToUser {
                hasZoomedToUser = true
                if MapViewModel.isInNorthernColorado(coordinate) {
                    mapView.setRegion(
                        MKCoordinateRegion(center: coordinate, span: BikeMapView.preferredSpan),
                        animated: true
                    )
                }
            }

            // Follow / heading-up camera while tracking.
            let movedEnough: Bool = {
                guard let last = lastPuckCoordinate else { return true }
                let a = CLLocation(latitude: last.latitude, longitude: last.longitude)
                return a.distance(from: location) >= 2
            }()
            lastPuckCoordinate = coordinate

            guard movedEnough else { return }
            // Don't yank the camera mid-pinch/rotate — that was blocking zoom during sim rides.
            guard !BikeMapView.isActivelyGesturing(mapView) else { return }

            switch trackingMode {
            case .follow:
                // North-up follow: keep the rider's zoom, flatten and reorient.
                let distance = mapView.camera.centerCoordinateDistance
                let camera = MKMapCamera(
                    lookingAtCenter: coordinate,
                    fromDistance: distance > 1 ? distance : 1_000,
                    pitch: 0,
                    heading: 0
                )
                mapView.setCamera(camera, animated: true)
            case .followWithHeading:
                // Preserve zoom/pitch so the rider can pinch in during navigation.
                let distance = mapView.camera.centerCoordinateDistance
                let pitch = mapView.camera.pitch
                let camera = MKMapCamera(
                    lookingAtCenter: coordinate,
                    fromDistance: distance > 1 ? distance : 450,
                    pitch: pitch > 1 ? pitch : 45,
                    heading: location.course >= 0 ? location.course : mapView.camera.heading
                )
                mapView.setCamera(camera, animated: true)
            default:
                break
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            // Fallback path while waiting for LocationProvider's first fix.
            guard parent.userPuckLocation == nil else { return }
            let coordinate = userLocation.coordinate
            DispatchQueue.main.async {
                self.parent.userCoordinate = coordinate
            }
            guard !hasZoomedToUser else { return }
            hasZoomedToUser = true
            // Skip auto-zoom when Simulator (or device) reports a far-away fix —
            // keep the Fort Collins startup region instead of jumping to SF.
            guard MapViewModel.isInNorthernColorado(coordinate) else { return }
            mapView.setRegion(
                MKCoordinateRegion(center: coordinate, span: BikeMapView.preferredSpan),
                animated: true
            )
        }

        @objc func handleScrollZoom(_ gesture: UIPanGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let dy = gesture.translation(in: mapView).y
            gesture.setTranslation(.zero, in: mapView)
            guard abs(dy) > 0.05 else { return }

            if parent.trackingMode != .none {
                DispatchQueue.main.async { self.parent.trackingMode = .none }
            }

            // Scroll up → zoom in (smaller span); scroll down → zoom out.
            let factor = exp(Double(dy) * 0.012)
            var region = mapView.region
            region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.0004), 60)
            region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0004), 60)
            mapView.setRegion(region, animated: false)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            DispatchQueue.main.async { self.parent.trackingMode = mode }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Planned route: thick indigo, distinct from facility colors and recommended rides
            if let polyline = overlay as? MKPolyline, overlay === plannedPolyline {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor(red: 0.35, green: 0.20, blue: 0.85, alpha: 0.95)
                r.lineWidth = 7
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }

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

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if annotation is UserLocationAnnotation {
                let reuseID = "user-location-puck"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? UserLocationAnnotationView)
                    ?? UserLocationAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
                view.annotation = annotation
                view.update(from: annotation)
                return view
            }

            guard annotation === destinationAnnotation else { return nil }

            let reuseID = "planned-destination"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation = annotation
            view.markerTintColor = UIColor(red: 0.35, green: 0.20, blue: 0.85, alpha: 1)
            view.glyphImage = UIImage(systemName: "flag.fill")
            view.canShowCallout = false
            return view
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = gesture.view as? MKMapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            parent.onLongPressDestination?(coordinate)
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

// MARK: - User location puck

final class UserLocationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var course: CLLocationDirection

    init(coordinate: CLLocationCoordinate2D, course: CLLocationDirection) {
        self.coordinate = coordinate
        self.course = course
        super.init()
    }
}

private final class UserLocationAnnotationView: MKAnnotationView {
    private let pulse = UIView()
    private let dot = UIView()
    private let heading = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 52, height: 52)
        centerOffset = .zero
        canShowCallout = false
        backgroundColor = .clear
        displayPriority = .required
        zPriority = .max
        layer.zPosition = 1000

        pulse.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.22)
        pulse.layer.cornerRadius = 18
        pulse.frame = CGRect(x: 8, y: 8, width: 36, height: 36)
        addSubview(pulse)

        dot.backgroundColor = UIColor.systemBlue
        dot.layer.cornerRadius = 11
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 3
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.35
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        dot.layer.shadowRadius = 2
        dot.frame = CGRect(x: 15, y: 15, width: 22, height: 22)
        addSubview(dot)

        heading.backgroundColor = UIColor.systemBlue
        heading.frame = CGRect(x: 24, y: 4, width: 4, height: 12)
        heading.layer.cornerRadius = 1
        addSubview(heading)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(from annotation: MKAnnotation?) {
        guard let puck = annotation as? UserLocationAnnotation else { return }
        heading.isHidden = puck.course < 0
        guard puck.course >= 0 else {
            transform = .identity
            return
        }
        let radians = CGFloat(puck.course * .pi / 180)
        transform = CGAffineTransform(rotationAngle: radians)
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
