import SwiftUI

/// PBAddSheet — add/edit a personal best for a swimmer.
/// Presented as .sheet() from SwimmerDetailView.
/// Stroke pills + distance pills + monospace time input.
struct PBAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    let swimmerId: String
    let onSave: (() -> Void)?

    private let swimmerService = SwimmerService()

    @State private var selectedStroke: String = "Free"
    @State private var selectedDistance: Int? = nil
    @State private var timeText: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let strokes = ["Free", "Back", "Breast", "Fly", "IM"]
    private let distances = [25, 50, 100, 200, 400, 800, 1500]

    private var canSave: Bool {
        selectedDistance != nil && !timeText.isEmpty && parseTimeMs(timeText) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                VStack(spacing: 28) {
                    strokePills
                    distancePills
                    timeInput
                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    saveButton
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Add Personal Best")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.accentCyan)
                }
            }
        }
    }

    private var strokePills: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stroke")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            HStack(spacing: 8) {
                ForEach(strokes, id: \.self) { stroke in
                    Button {
                        selectedStroke = stroke
                    } label: {
                        Text(stroke)
                            .font(.captionStrong)
                            .foregroundColor(selectedStroke == stroke ? Color.bgBase : Color.textMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedStroke == stroke ? Color.accentCyan : Color.bgInset)
                            .cornerRadius(20)
                    }
                }
            }
        }
    }

    private var distancePills: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Distance")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            FlowLayout(spacing: 8) {
                ForEach(distances, id: \.self) { d in
                    Button {
                        selectedDistance = d
                    } label: {
                        Text("\(d)")
                            .font(.captionStrong)
                            .foregroundColor(selectedDistance == d ? Color.bgBase : Color.textMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedDistance == d ? Color.accentCyan : Color.bgInset)
                            .cornerRadius(20)
                    }
                }
            }
        }
    }

    private var timeInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIME (mm:ss.SS)")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            TextField("0:00.00", text: $timeText)
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .foregroundColor(Color.textPrimary)
                .multilineTextAlignment(.center)
                .padding(16)
                .background(Color.bgInset)
                .cornerRadius(12)
                .keyboardType(.numbersAndPunctuation)
        }
    }

    private var saveButton: some View {
        Button {
            guard let distance = selectedDistance, let timeMs = parseTimeMs(timeText) else { return }
            isSaving = true
            Task {
                do {
                    _ = try await swimmerService.upsertPersonalBest(swimmerId: swimmerId, distance: distance, stroke: selectedStroke, timeMs: timeMs, gear: nil)
                    onSave?()
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        } label: {
            Text("Save PB")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(canSave ? Color.bgBase : Color.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(canSave ? Color.accentCyan : Color.bgInset)
                .cornerRadius(12)
        }
        .disabled(!canSave || isSaving)
    }

    /// Parse "1:03.45" or "63.45" → milliseconds. Returns nil if unparseable.
    private func parseTimeMs(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        // "1:03.45" format
        if let colonIdx = cleaned.firstIndex(of: ":") {
            let minStr = String(cleaned[..<colonIdx])
            let secStr = String(cleaned[cleaned.index(after: colonIdx)...])
            guard let mins = Int(minStr), let secParts = parseSeconds(secStr) else { return nil }
            return mins * 60 * 1000 + secParts
        }
        // Plain seconds "63.45"
        guard let secs = parseSeconds(cleaned) else { return nil }
        return secs
    }

    private func parseSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ".", maxSplits: 1)
        guard parts.count <= 2 else { return nil }
        let mainSecs = Int(parts[0]) ?? 0
        let centis: Int
        if parts.count == 2 {
            let frac = parts[1].padding(toLength: 2, withPad: "0", startingAt: 0)
            centis = (Int(frac) ?? 0) * 10
        } else { centis = 0 }
        return mainSecs * 1000 + centis
    }
}
