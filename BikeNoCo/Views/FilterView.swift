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

                Section {
                    Text("Bike facilities from the City of Fort Collins and City of Loveland. Street connectors © OpenStreetMap contributors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Data Sources")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
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
