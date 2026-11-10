import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var locationMonitor = LocationPermissionMonitor()
    @StateObject private var locationProvider: LocationProvider
    @StateObject private var recorder: RideRecorder
    @StateObject private var navigation: NavigationController
    @State private var showFilters = false
    @State private var showStylePicker = false
    @State private var showPlanLoop = false
    @State private var selectedRoute: BikeRoute?
    @State private var locationBannerDismissed = false
    @State private var completedSession: RideSession?
    @State private var showTurnsSheet = false
    @State private var focusCoordinate: CLLocationCoordinate2D?
    @State private var gpxShareURL: URL?

    init() {
        let provider = LocationProvider()
        _locationProvider = StateObject(wrappedValue: provider)
        _recorder = StateObject(wrappedValue: RideRecorder(locationProvider: provider))
        _navigation = StateObject(wrappedValue: NavigationController(locationProvider: provider))
    }

    private var isRecording: Bool { recorder.state == .recording }
    private var isNavigating: Bool { navigation.isNavigating }

    var body: some View {
        ZStack {
            BikeMapView(
                routes: viewModel.filteredRoutes,
                activeRoute: viewModel.activeRoute,
                plannedRoute: viewModel.plannedRoute,
                routeDestination: viewModel.routeDestination,
                remainingRouteCoordinates: isNavigating ? navigation.remainingRouteCoordinates : nil,
                userPuckLocation: locationProvider.latestLocation,
                selectedRoute: $selectedRoute,
                userCoordinate: $viewModel.userCoordinate,
                mapType: viewModel.mapStyle.mapType,
                trackingMode: $viewModel.trackingMode,
                focusRouteID: $viewModel.focusRouteID,
                focusCoordinate: $focusCoordinate,
                cameraCommand: $viewModel.cameraCommand,
                onLongPressDestination: { coordinate in
                    guard !isNavigating else { return }
                    viewModel.planRoute(to: coordinate)
                }
            )
            .ignoresSafeArea()

            if viewModel.isLoading {
                LoadingOverlay(progress: viewModel.loadProgress)
            }

            if let error = viewModel.errorMessage {
                ErrorBanner(message: error)
            }

            if let routingError = viewModel.routingError {
                ErrorBanner(message: routingError.friendlyMessage)
            }

            if locationMonitor.isDenied && !locationBannerDismissed {
                LocationPermissionBanner {
                    withAnimation(.spring(duration: 0.3)) { locationBannerDismissed = true }
                }
                .animation(.spring(duration: 0.4), value: locationMonitor.isDenied)
            }

            // Active route banner — shown when a suggested ride is selected
            if let route = viewModel.activeRoute {
                ActiveRouteBanner(routeName: route.streetName) {
                    withAnimation(.spring(duration: 0.3)) {
                        viewModel.activeRouteID = nil
                    }
                }
            }

            if isNavigating {
                NavigationHUD(
                    nextManeuver: navigation.nextManeuver,
                    distanceToNextMeters: navigation.progress?.distanceToNextManeuver ?? 0,
                    remainingDistanceMeters: navigation.remainingDistanceMeters,
                    eta: navigation.etaDate,
                    navigationState: navigation.state,
                    isMuted: navigation.isMuted,
                    onToggleMute: { navigation.isMuted.toggle() },
                    onEnd: { endNavigationAndRecording() }
                )
            } else if isRecording {
                LiveRideHUD(
                    elapsed: recorder.elapsedTime,
                    distanceMiles: recorder.liveDistanceMeters / 1609.344,
                    speedMPH: recorder.liveSpeedMPS * 2.23694,
                    isPaused: recorder.isPaused,
                    showAutoResumeHint: recorder.isManuallyPaused,
                    onTogglePause: { recorder.toggleManualPause() },
                    onStop: { recorder.stopRecording() }
                )
            }

            // Right-side control column
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    MapControlButton(
                        systemImage: isRecording ? "stop.circle.fill" : "record.circle",
                        tint: .red,
                        isActive: isRecording,
                        pulse: isRecording && !recorder.isPaused
                    ) {
                        if isRecording {
                            endNavigationAndRecording()
                        } else {
                            recorder.startRecording()
                        }
                    }

                    MapControlButton(
                        systemImage: "location.fill",
                        isActive: viewModel.trackingMode == .follow
                    ) {
                        viewModel.toggleLocationTracking()
                    }

                    MapControlButton(
                        systemImage: "arrow.triangle.2.circlepath",
                        isActive: showPlanLoop
                    ) {
                        showPlanLoop = true
                    }

                    MapControlButton(systemImage: "plus.magnifyingglass") {
                        viewModel.trackingMode = .none
                        viewModel.cameraCommand = .zoomIn
                    }

                    MapControlButton(systemImage: "minus.magnifyingglass") {
                        viewModel.trackingMode = .none
                        viewModel.cameraCommand = .zoomOut
                    }

                    MapControlButton(
                        systemImage: viewModel.mapStyle.icon,
                        isActive: showStylePicker
                    ) {
                        showStylePicker.toggle()
                    }
                    .popover(isPresented: $showStylePicker, arrowEdge: .trailing) {
                        MapStylePicker(current: viewModel.mapStyle) { viewModel.mapStyle = $0 }
                    }

                    MapControlButton(
                        systemImage: "line.3.horizontal.decrease.circle",
                        isActive: showFilters
                    ) {
                        showFilters = true
                    }
                }
                .padding(.top, (isRecording || isNavigating) ? 110 : 60)
                .padding(.trailing, 12)
                .animation(.spring(duration: 0.3), value: isRecording || isNavigating)
            }

            if viewModel.isPreparingRoutes {
                VStack {
                    Spacer()
                    ProgressView("Preparing routes…")
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, viewModel.plannedRoute == nil ? 40 : 160)
                }
            }

            if viewModel.isRouting {
                VStack {
                    Spacer()
                    ProgressView("Finding route…")
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 40)
                }
            }

            if let planned = viewModel.plannedRoute, !isNavigating {
                VStack {
                    Spacer()
                    plannedRouteCard(for: planned)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: viewModel.plannedRoute?.totalDistanceMeters)
        .animation(.spring(duration: 0.3), value: isNavigating)
        .sheet(isPresented: $showFilters) {
            FilterView(viewModel: viewModel)
        }
        .sheet(isPresented: $showPlanLoop) {
            PlanLoopSheet(
                viewModel: viewModel,
                onClose: { showPlanLoop = false },
                onPreview: { candidate in
                    viewModel.selectLoopCandidate(candidate)
                    showPlanLoop = false
                },
                onStart: { candidate in
                    viewModel.selectLoopCandidate(candidate)
                    showPlanLoop = false
                    if let planned = viewModel.plannedRoute {
                        startNavigation(route: planned)
                    }
                }
            )
        }
        .sheet(isPresented: $showTurnsSheet) {
            if let planned = viewModel.plannedRoute {
                ManeuverListSheet(route: planned) { coordinate in
                    showTurnsSheet = false
                    focusCoordinate = coordinate
                }
            }
        }
        .sheet(item: $selectedRoute) { route in
            RouteDetailView(route: route)
        }
        .sheet(item: $completedSession, onDismiss: { recorder.discardAndReset() }) { session in
            RideSummaryView(session: session) {
                completedSession = nil
                recorder.discardAndReset()
            }
        }
        .sheet(item: Binding(
            get: { gpxShareURL.map(IdentifiableURL.init) },
            set: { gpxShareURL = $0?.url }
        )) { item in
            ShareSheet(items: [item.url])
        }
        .onChange(of: recorder.state) { _, newState in
            if case .finished(let session) = newState {
                completedSession = session
            }
        }
        .task {
            locationMonitor.requestWhenInUseIfNeeded()
            // Keep a live fix for the map puck + routing origin from launch,
            // not only after the rider starts recording/navigating.
            locationProvider.requestAuthorizationIfNeeded()
            locationProvider.startUpdating(for: locationMonitor)
            await viewModel.loadRoutes()
        }
        .onChange(of: locationProvider.latestLocation?.timestamp) { _, _ in
            if let coordinate = locationProvider.latestLocation?.coordinate {
                viewModel.userCoordinate = coordinate
            }
        }
    }

    @ViewBuilder
    private func plannedRouteCard(for planned: PlannedRoute) -> some View {
        #if DEBUG
        PlannedRouteCard(
            route: planned,
            tripShape: viewModel.tripShape,
            showsTripShapePicker: !viewModel.plannedRouteIsDistanceLoop,
            onTripShapeChange: { viewModel.setTripShape($0) },
            onClear: { viewModel.clearPlannedRoute() },
            onShowTurns: { showTurnsSheet = true },
            onStart: { startNavigation(route: planned) },
            onExportGPX: { exportGPX(for: planned) },
            onSimulateRide: { injectDetour in
                startSimulatedNavigation(route: planned, injectDetour: injectDetour)
            }
        )
        #else
        PlannedRouteCard(
            route: planned,
            tripShape: viewModel.tripShape,
            showsTripShapePicker: !viewModel.plannedRouteIsDistanceLoop,
            onTripShapeChange: { viewModel.setTripShape($0) },
            onClear: { viewModel.clearPlannedRoute() },
            onShowTurns: { showTurnsSheet = true },
            onStart: { startNavigation(route: planned) }
        )
        #endif
    }

    private func startNavigation(route: PlannedRoute) {
        guard let graph = viewModel.routingGraph else {
            viewModel.routingError = .noPath(hint: "Bike network is still loading. Try again in a moment.")
            return
        }
        if recorder.state != .recording {
            recorder.startRecording()
        }
        navigation.start(route: route, graph: graph)
        viewModel.trackingMode = .followWithHeading
    }

    private func endNavigationAndRecording() {
        if navigation.isNavigating {
            navigation.end()
        }
        if recorder.state == .recording {
            recorder.stopRecording()
        }
        if viewModel.trackingMode == .followWithHeading {
            viewModel.trackingMode = .follow
        }
    }

    #if DEBUG
    private func startSimulatedNavigation(route: PlannedRoute, injectDetour: Bool) {
        guard let graph = viewModel.routingGraph else {
            viewModel.routingError = .noPath(hint: "Bike network is still loading. Try again in a moment.")
            return
        }
        if recorder.state != .recording {
            recorder.startRecording()
        }
        navigation.startSimulatedRide(route: route, graph: graph, injectDetour: injectDetour)
        viewModel.trackingMode = .followWithHeading
    }

    private func exportGPX(for route: PlannedRoute) {
        do {
            gpxShareURL = try GPXExporter.writeTemporaryFile(for: route)
        } catch {
            NSLog("[BikeNoCo] GPX export failed: %@", error.localizedDescription)
        }
    }
    #endif
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Planned route card

private struct PlannedRouteCard: View {
    let route: PlannedRoute
    let tripShape: TripShape
    var showsTripShapePicker: Bool = true
    let onTripShapeChange: (TripShape) -> Void
    let onClear: () -> Void
    let onShowTurns: () -> Void
    let onStart: () -> Void
    var onExportGPX: (() -> Void)?
    var onSimulateRide: ((Bool) -> Void)?

    private var distanceMiles: String {
        String(format: "%.1f mi", route.totalDistanceMeters / 1609.344)
    }

    private var lowStressPercent: String {
        String(format: "%.0f%% low-stress", route.lowStressShare * 100)
    }

    private var connectorPercent: String? {
        guard route.connectorShare > 0.005 else { return nil }
        return String(format: "%.0f%% on streets", route.connectorShare * 100)
    }

    private var namesLine: String {
        let names = route.dominantNames
        if names.isEmpty { return "Bike network" }
        return names.joined(separator: " · ")
    }

    private var loopDifferenceLine: String? {
        guard route.tripShape == .loop, let overlap = route.overlapShare else { return nil }
        let different = max(0, 1 - overlap) * 100
        return String(format: "%.0f%% different from the way out", different)
    }

    private var highOverlapNote: String? {
        guard route.tripShape == .loop, let overlap = route.overlapShare, overlap > 0.60 else {
            return nil
        }
        return "Few alternate ways back here; much of the return repeats the outbound route."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(distanceMiles)
                        .font(.title2.bold())
                    Text(lowStressPercent)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let connectorPercent {
                        Text(connectorPercent)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let loopDifferenceLine {
                        Text(loopDifferenceLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Clear", action: onClear)
                    .font(.subheadline.weight(.semibold))
            }

            Text(namesLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let highOverlapNote {
                Text(highOverlapNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if showsTripShapePicker {
                Picker("Trip shape", selection: Binding(
                    get: { tripShape },
                    set: onTripShapeChange
                )) {
                    ForEach(TripShape.allCases) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
            } else if route.tripShape == .loop {
                Text(String(format: "%.0f%% trail", route.trailShare * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(action: onShowTurns) {
                    Label("Turns", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onStart) {
                    Label("Start", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            #if DEBUG
            if let onExportGPX {
                Button(action: onExportGPX) {
                    Label("Export GPX", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
            if let onSimulateRide {
                HStack(spacing: 10) {
                    Button {
                        onSimulateRide(false)
                    } label: {
                        Label("Simulate Ride", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)

                    Button {
                        onSimulateRide(true)
                    } label: {
                        Label("Sim + Detour", systemImage: "arrow.triangle.swap")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
            #endif
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private struct ManeuverListSheet: View {
    let route: PlannedRoute
    let onSelect: (CLLocationCoordinate2D) -> Void

    private var maneuvers: [Maneuver] {
        ManeuverBuilder.build(from: route)
    }

    var body: some View {
        NavigationStack {
            List(maneuvers) { maneuver in
                Button {
                    onSelect(maneuver.coordinate)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: maneuver.type.systemImage)
                            .font(.title3)
                            .frame(width: 28)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(maneuver.instruction)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if maneuver.type != .arrive {
                                Text(DistanceFormat.imperial(maneuver.distanceToNext))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Turns")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Active route banner

private struct ActiveRouteBanner: View {
    let routeName: String
    let onClear: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "figure.outdoor.cycle")
                    .font(.subheadline)
                    .foregroundStyle(Color(FacilityType.recommendedRide.color))

                Text(routeName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 18))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 60)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Control button

private struct MapControlButton: View {
    let systemImage: String
    var tint: Color = .accentColor
    var isActive: Bool = false
    var pulse: Bool = false
    let action: () -> Void

    @State private var pulsing = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(isActive ? tint : Color(.systemBackground).opacity(0.92))
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                .scaleEffect(pulsing ? 1.08 : 1.0)
        }
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .onChange(of: pulse) { _, on in
            if !on { pulsing = false }
        }
    }
}

// MARK: - Map style picker

private struct MapStylePicker: View {
    var current: MapStyle
    var onSelect: (MapStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Map Style")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            styleRow(.standard)
            styleRow(.muted)
            styleRow(.satellite)
            styleRow(.hybrid)
        }
        .padding(.bottom, 8)
        .frame(width: 180)
        .presentationCompactAdaptation(.popover)
    }

    private func styleRow(_ style: MapStyle) -> some View {
        Button {
            onSelect(style)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: style.icon).frame(width: 20)
                Text(style.rawValue)
                Spacer()
                if current == style {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Supporting views

private struct LocationPermissionBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "location.slash.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Location Access Needed")
                        .font(.subheadline.bold())
                    Text("To show your position on the map, go to **Settings → Privacy & Security → Location Services → BikeNoCo** and select \"While Using the App\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 60)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct LoadingOverlay: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 200)
            Text("Loading bike routes…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 60)
            Spacer()
        }
    }
}
