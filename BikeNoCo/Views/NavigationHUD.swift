import SwiftUI

struct NavigationHUD: View {
    let nextManeuver: Maneuver?
    let distanceToNextMeters: Double
    let remainingDistanceMeters: Double
    let eta: Date?
    let navigationState: NavigationState
    let isMuted: Bool
    let onToggleMute: () -> Void
    let onEnd: () -> Void

    private var isOffRouteBanner: Bool {
        navigationState == .offRoute || navigationState == .rerouting
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: nextManeuver?.type.systemImage ?? "arrow.up")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(DistanceFormat.imperial(distanceToNextMeters))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(streetLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(DistanceFormat.imperial(remainingDistanceMeters))
                        .font(.footnote.monospacedDigit().weight(.semibold))
                    if let eta {
                        Text(eta, style: .time)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button(action: onToggleMute) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .background(Color(.systemBackground).opacity(0.85), in: Circle())
                        }
                        .accessibilityLabel(isMuted ? "Unmute" : "Mute")

                        Button(action: onEnd) {
                            Text("End")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.red, in: Capsule())
                        }
                    }
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if isOffRouteBanner {
                Text(navigationState == .rerouting ? "Rerouting…" : "Off route — finding a new path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }

            Spacer()
        }
    }

    private var streetLine: String {
        if let name = nextManeuver?.streetName, !name.isEmpty {
            return name
        }
        return nextManeuver?.instruction ?? "Continue"
    }
}
