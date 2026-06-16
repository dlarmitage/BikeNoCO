import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var locationMonitor = LocationPermissionMonitor()
    @StateObject private var recorder = RideRecorder()
    @State private var showFilters = false
    @State private var showStylePicker = false
    @State private var selectedRoute: BikeRoute?
    @State private var locationBannerDismissed = false
    @State private var completedSession: RideSession?

    private var isRecording: Bool { recorder.state == .recording }

    var body: some View {
        ZStack {
            BikeMapView(
                routes: viewModel.filteredRoutes,
                activeRoute: viewModel.activeRoute,
                selectedRoute: $selectedRoute,
                mapType: viewModel.mapStyle.mapType,
                trackingMode: $viewModel.trackingMode,
                focusRouteID: $viewModel.focusRouteID
            )
            .ignoresSafeArea()

            if viewModel.isLoading {
                LoadingOverlay(progress: viewModel.loadProgress)
            }

            if let error = viewModel.errorMessage {
                ErrorBanner(message: error)
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

            if isRecording {
                LiveRideHUD(
                    elapsed: recorder.elapsedTime,
                    distanceMiles: recorder.liveDistanceMeters / 1609.344,
                    speedMPH: recorder.liveSpeedMPS * 2.23694,
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
                        pulse: isRecording
                    ) {
                        isRecording ? recorder.stopRecording() : recorder.startRecording()
                    }

                    MapControlButton(
                        systemImage: "location.fill",
                        isActive: viewModel.trackingMode == .follow
                    ) {
                        viewModel.trackingMode = viewModel.trackingMode == .follow ? .none : .follow
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
                .padding(.top, isRecording ? 90 : 60)
                .padding(.trailing, 12)
                .animation(.spring(duration: 0.3), value: isRecording)
            }
        }
        .sheet(isPresented: $showFilters) {
            FilterView(viewModel: viewModel)
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
        .onChange(of: recorder.state) { _, newState in
            if case .finished(let session) = newState {
                completedSession = session
            }
        }
        .task {
            await viewModel.loadRoutes()
        }
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
