import SwiftUI

struct LiveRideHUD: View {
    let elapsed: TimeInterval
    let distanceMiles: Double
    let speedMPH: Double
    let onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StatColumn(value: formatTime(elapsed), label: "Duration")
                Divider().frame(height: 36)
                StatColumn(value: String(format: "%.2f", distanceMiles), label: "Miles")
                Divider().frame(height: 36)
                StatColumn(value: String(format: "%.1f", speedMPH), label: "mph")

                Divider().frame(height: 36)

                Button(action: onStop) {
                    VStack(spacing: 2) {
                        ZStack {
                            Circle()
                                .fill(.red.opacity(0.15))
                                .frame(width: 28, height: 28)
                                .scaleEffect(pulse ? 1.2 : 1.0)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.red)
                                .frame(width: 13, height: 13)
                        }
                        Text("Stop")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .frame(width: 58)
                }
            }
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        let s = Int(interval) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

private struct StatColumn: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
