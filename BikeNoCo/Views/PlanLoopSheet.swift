import SwiftUI

struct PlanLoopSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let onClose: () -> Void
    let onPreview: (LoopCandidate) -> Void
    let onStart: (LoopCandidate) -> Void

    @State private var detent: PresentationDetent = .fraction(0.72)

    private var streetComfortSelection: Binding<String> {
        Binding(
            get: {
                switch viewModel.loopMaxLTS {
                case 1: return "quietest"
                case 2: return "calmer"
                default: return "any"
                }
            },
            set: { value in
                switch value {
                case "quietest": viewModel.loopMaxLTS = 1
                case "calmer": viewModel.loopMaxLTS = 2
                default: viewModel.loopMaxLTS = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Distance")
                            Spacer()
                            Text(String(format: "%.0f mi", viewModel.loopTargetMiles))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $viewModel.loopTargetMiles, in: 3...40, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Busy streets")
                        Picker("Busy streets", selection: streetComfortSelection) {
                            Text("Any").tag("any")
                            Text("Calmer").tag("calmer")
                            Text("Quietest").tag("quietest")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Toggle("Prefer trails", isOn: $viewModel.loopPreferTrails)

                    Picker("Start", selection: $viewModel.loopStartUsesPin) {
                        Text("Current location").tag(false)
                        Text("Map pin").tag(true)
                    }
                } header: {
                    Text("Search")
                } footer: {
                    Text(startFooterText)
                }

                Section {
                    Button {
                        detent = .large
                        viewModel.searchLoops()
                    } label: {
                        if viewModel.isSearchingLoops {
                            HStack {
                                ProgressView()
                                Text(viewModel.loopCandidates.isEmpty ? "Finding loops…" : "Finding more…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Find Loops", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.isSearchingLoops)

                    if let seconds = viewModel.lastLoopSearchSeconds,
                       !viewModel.isSearchingLoops,
                       !viewModel.loopCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "Found in %.2f s", seconds))
                            if let first = viewModel.lastLoopTimeToFirstSeconds {
                                Text(String(format: "First result in %.2f s", first))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let error = viewModel.loopSearchError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if !viewModel.loopCandidates.isEmpty {
                    Section("Results") {
                        ForEach(viewModel.loopCandidates) { candidate in
                            LoopCandidateRow(candidate: candidate) {
                                onPreview(candidate)
                            } onStart: {
                                onStart(candidate)
                            }
                        }
                    }

                    if !viewModel.isSearchingLoops {
                        Section("Refine") {
                            HStack(spacing: 8) {
                                refinementChip("Shorter") { viewModel.refineLoopsShorter() }
                                refinementChip("Longer") { viewModel.refineLoopsLonger() }
                                refinementChip("More trail") { viewModel.refineLoopsMoreTrail() }
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                }
            }
            .navigationTitle("Plan a loop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        viewModel.cancelLoopSearch()
                        onClose()
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.72), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.72)))
    }

    private var startFooterText: String {
        if viewModel.loopStartUsesPin {
            if viewModel.routeDestination == nil {
                return "Long-press the map to drop a start pin, then tap Find Loops."
            }
            return "Using your dropped map pin as the start."
        }
        return "Calmer / Quietest limit busy streets using Level of Traffic Stress (LTS). Quietest is LTS 1 only; Calmer allows up to LTS 2."
    }

    private func refinementChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .disabled(viewModel.isSearchingLoops)
    }
}

private struct LoopCandidateRow: View {
    let candidate: LoopCandidate
    let onPreview: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(Color(red: 0.35, green: 0.20, blue: 0.85))
                    .frame(width: 10, height: 10)
                Text(candidate.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(String(format: "%.1f mi", candidate.distanceMeters / 1609.344))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(
                String(
                    format: "%.0f%% low-stress · %.0f%% trail · %.0f%% unique",
                    candidate.lowStressShare * 100,
                    candidate.trailShare * 100,
                    max(0, 1 - candidate.overlapShare) * 100
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Preview", action: onPreview)
                    .buttonStyle(.bordered)
                Button("Start", action: onStart)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
