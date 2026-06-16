import SwiftUI

struct FilterView: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss

    private var infrastructureTypes: [FacilityType] {
        FacilityType.allCases.filter { $0 != .recommendedRide }
    }

    var body: some View {
        NavigationStack {
            List {
                if !viewModel.recommendedRoutes.isEmpty {
                    Section {
                        ForEach(viewModel.recommendedRoutes) { route in
                            SuggestedRideRow(
                                route: route,
                                isActive: viewModel.activeRouteID == route.id,
                                onTap: {
                                    if viewModel.activeRouteID == route.id {
                                        viewModel.activeRouteID = nil
                                    } else {
                                        viewModel.activeRouteID = route.id
                                        viewModel.focusRouteID = route.id
                                    }
                                }
                            )
                        }
                    } header: {
                        Text("Suggested Rides")
                    } footer: {
                        if viewModel.activeRouteID != nil {
                            Text("Tap Done when you're ready to ride.")
                        } else {
                            Text("Tap a ride to preview it on the map.")
                        }
                    }
                }

                Section {
                    HStack {
                        Button("Show All") { viewModel.showAll() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Hide All") { viewModel.hideAll() }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                    }
                }

                Section("Route Types") {
                    ForEach(infrastructureTypes, id: \.self) { type in
                        FilterRow(
                            type: type,
                            isOn: viewModel.visibleTypes.contains(type),
                            toggle: { viewModel.toggleType(type) }
                        )
                    }
                }
            }
            .navigationTitle("Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(viewModel.activeRouteID != nil ? .bold : .regular)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}

// MARK: - Suggested ride row

private struct SuggestedRideRow: View {
    let route: BikeRoute
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(FacilityType.recommendedRide.color))
                        .frame(width: 22, height: 4)

                    Text(route.streetName)
                        .font(.subheadline)
                        .fontWeight(isActive ? .semibold : .regular)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color(FacilityType.recommendedRide.color) : .secondary)
                        .font(.system(size: 18))
                }

                HStack(spacing: 16) {
                    if let dist = route.formattedDistance {
                        Label(dist, systemImage: "arrow.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let gain = route.formattedElevationGain {
                        Label(gain, systemImage: "mountain.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isActive, let desc = route.routeDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isActive
                ? Color(FacilityType.recommendedRide.color).opacity(0.08)
                : Color.clear
        )
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

// MARK: - Infrastructure filter row

private struct FilterRow: View {
    let type: FacilityType
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(type.color))
                    .frame(width: 28, height: 5)

                Text(type.displayName)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color(type.color) : .secondary)
            }
        }
        .listRowBackground(isOn ? Color(type.color).opacity(0.05) : Color.clear)
    }
}
