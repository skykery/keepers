import KeepersCore
import SwiftUI

/// Opens the custom settings next to the preset picker.
struct CustomSettingsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Label("Custom Settings", systemImage: "slider.horizontal.3") }
            .help("Edit the custom settings")
            .popover(isPresented: $showing, arrowEdge: .bottom) { CustomSettingsView().padding(16).frame(width: 340) }
    }
}

struct CustomSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom").font(.headline)
            slider("Top Picks", value: $model.customSettings.pickFraction, in: 0.01...0.5, step: 0.01,
                   text: "\(Int((model.customSettings.pickFraction * 100).rounded()))% of usable shots")
            Stepper(value: $model.customSettings.keepPerGroup, in: 1...10) {
                LabeledText(label: "Similar shots kept", value: "best \(model.customSettings.keepPerGroup) of each group")
            }
            slider("Out of focus below", value: $model.customSettings.minSharpness, in: 0.05...0.5, step: 0.01,
                   text: "sharpness \(Int((model.customSettings.minSharpness * 100).rounded()))")
            slider("Weaker duplicate gap", value: $model.customSettings.duplicateGap, in: 0.01...0.2, step: 0.01,
                   text: "\(Int((model.customSettings.duplicateGap * 100).rounded())) points below the best")
            HStack {
                Text("Changes apply right away.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.customSettings = Preset.balanced.settings }
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledText(label: label, value: text)
            Slider(value: value, in: range, step: step)
        }
    }
}

struct LabeledText: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// What Keepers learned from manual moves, and the switch to use it.
struct TasteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var samples: [Taste.Sample] = []
    @State private var fit: Taste.Fit?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Learn from your choices").font(.title3.weight(.semibold))
            Text("Every photo you move by hand is remembered with its sharpness, exposure, and aesthetics. Keepers looks for the weighting that orders those choices the way you did: Top Picks and Moments above Review, Review above Trash. Nothing leaves this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let fit {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text(""); Text("Default").bold(); Text("Learned").bold() }
                    row("Sharpness", ScoringWeights().sharpness, fit.weights.sharpness)
                    row("Exposure", ScoringWeights().exposure, fit.weights.exposure)
                    row("Aesthetics", ScoringWeights().aesthetics, fit.weights.aesthetics)
                    Divider().gridCellColumns(3)
                    GridRow {
                        Text("Agrees with you")
                        Text(percent(fit.defaultAgreement)).monospacedDigit()
                        Text(percent(fit.agreement)).monospacedDigit()
                    }
                }
                Text("From your last \(fit.samples) choices.").font(.caption).foregroundStyle(.secondary)
                if fit.agreement <= fit.defaultAgreement + 0.01 {
                    Text("The default weighting already matches your choices.").font(.callout)
                }
            } else {
                Label("Not enough choices yet: \(samples.count) of at least \(Taste.minimumSamples), spread over at least two of Top Picks / Moments, Review, and Trash.",
                      systemImage: "hourglass")
                    .font(.callout)
            }

            HStack {
                Button("Forget My Choices", role: .destructive) {
                    Taste.reset()
                    model.learnedWeights = nil
                    Task { await load() }
                }
                .disabled(samples.isEmpty)
                Spacer()
                if model.learnedWeights != nil {
                    Button("Use Default Weights") { model.learnedWeights = nil }
                }
                if let fit, fit.agreement > fit.defaultAgreement + 0.01, model.learnedWeights != fit.weights {
                    Button("Use Learned Weights") { model.learnedWeights = fit.weights }
                        .buttonStyle(.borderedProminent)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
    }

    private func load() async {
        loading = true
        let loaded = await Task.detached { Taste.load() }.value
        samples = loaded
        fit = await Task.detached { Taste.fit(loaded) }.value
        loading = false
    }

    private func row(_ label: String, _ a: Double, _ b: Double) -> some View {
        GridRow {
            Text(label)
            Text(percent(a)).monospacedDigit()
            Text(percent(b)).monospacedDigit().foregroundStyle(abs(a - b) > 0.001 ? Color.accentColor : .primary)
        }
    }

    private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}
