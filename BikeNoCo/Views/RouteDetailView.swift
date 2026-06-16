import SwiftUI

struct RouteDetailView: View {
    let route: BikeRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledRow(label: "Street", value: route.streetName.isEmpty ? "Unknown" : route.streetName)
                    LabeledRow(label: "Facility Type", value: route.facilityType.displayName)
                    if let bikeway = route.bikewayName {
                        LabeledRow(label: "Bikeway", value: bikeway)
                    }
                }

                if route.facilityType == .recommendedRide {
                    Section("Ride Stats") {
                        if let dist = route.formattedDistance {
                            LabeledRow(label: "Distance", value: dist)
                        }
                        if let gain = route.formattedElevationGain {
                            LabeledRow(label: "Elevation Gain", value: gain)
                        }
                    }
                    if let desc = route.routeDescription, !desc.isEmpty {
                        Section("Description") {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("Traffic") {
                        HStack {
                            Text("Stress Level")
                                .foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(route.stressColor))
                                    .frame(width: 10, height: 10)
                                Text(route.stressLabel)
                                    .bold()
                            }
                        }
                        if let speed = route.speedLimit {
                            LabeledRow(label: "Speed Limit", value: "\(speed) mph")
                        }
                    }

                    if let lts = route.lts {
                        Section {
                            StressBar(level: lts)
                        } header: {
                            Text("Level of Traffic Stress")
                        } footer: {
                            Text("LTS 1–2 is suitable for most riders. LTS 3–4 is for experienced cyclists.")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(route.streetName.isEmpty ? "Route Details" : route.streetName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct StressBar: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i <= level ? barColor(i) : Color.secondary.opacity(0.2))
                    .frame(height: 8)
            }
        }
    }

    private func barColor(_ i: Int) -> Color {
        switch i {
        case 1: return Color(red: 0.18, green: 0.80, blue: 0.44)
        case 2: return Color(red: 0.95, green: 0.77, blue: 0.06)
        case 3: return Color(red: 0.90, green: 0.49, blue: 0.13)
        case 4: return Color(red: 0.91, green: 0.30, blue: 0.24)
        default: return .gray
        }
    }
}
