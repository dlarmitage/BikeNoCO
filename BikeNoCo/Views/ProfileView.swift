import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var weightPounds: Double = RiderSettings.weightPounds
    @State private var bikeType: BikeType = RiderSettings.bikeType
    @State private var detent: PresentationDetent = .fraction(0.72)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField(
                            "lb",
                            value: $weightPounds,
                            format: .number.precision(.fractionLength(0))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        Text("lb")
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: weightPounds) { _, newValue in
                        RiderSettings.weightPounds = newValue
                    }
                } header: {
                    Text("Body")
                } footer: {
                    Text("Used for calorie estimates. Default is 154 lb (70 kg).")
                }

                Section {
                    ForEach(BikeType.allCases) { type in
                        Button {
                            bikeType = type
                            RiderSettings.bikeType = type
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: type.systemImage)
                                    .frame(width: 28)
                                    .foregroundStyle(.primary)
                                Text(type.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if bikeType == type {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Bike")
                } footer: {
                    Text("Calorie burn at the same speed is higher on gravel or mountain bikes, and lower on an e-bike.")
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.72), .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }
}
