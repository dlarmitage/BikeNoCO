import SwiftUI

struct PlanLoopSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let onClose: () -> Void
    let onPreview: (LoopCandidate) -> Void
    let onStart: (LoopCandidate) -> Void

    private var maxLTSSelection: Binding<String> {
        Binding(
            get: {
                if let max = viewModel.loopMaxLTS { return String(max) }
                return "any"
            },
            set: { value in
                viewModel.loopMaxLTS = value == "any" ? nil : Int(value)
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

                    Picker("Max LTS", selection: maxLTSSelection) {
                        Text("Any").tag("any")
                        Text("≤ 2").tag("2")
                        Text("≤ 1").tag("1")
                    }

                    Toggle("Prefer trails", isOn: $viewModel.loopPreferTrails)

                    LabeledContent("Start") {
                        Text(viewModel.loopSearchUsesPin ? "Dropped pin" : "Current location")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Search")
                } footer: {
                    Text("Loops are triangles of low-stress bike routes near your target distance.")
                }

                Section {
                    Button {
                        viewModel.searchLoops()
                    } label: {
                        if viewModel.isSearchingLoops && viewModel.loopCandidates.isEmpty {
                            HStack {
                                ProgressView()
                                Text("Finding loops…")
                            }
                        } else {
                            Label("Find Loops", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(viewModel.isSearchingLoops)

                    if viewModel.isSearchingLoops, !viewModel.loopCandidates.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Finding more…")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    } else if let seconds = viewModel.lastLoopSearchSeconds, !viewModel.loopCandidates.isEmpty {
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
