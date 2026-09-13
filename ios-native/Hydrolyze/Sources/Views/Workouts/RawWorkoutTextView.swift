import SwiftUI

/// V0.55 S0a (2026-09-13): the "As written" surface for
/// `WorkoutDetailView`. Renders the coach's raw text exactly as they
/// submitted it — no normalisation, no truncation, no ellipsis — with
/// lightweight line classification + in-place syntax highlighting.
///
/// Design contract (V0.55 spec §"As-written surface"):
/// - **Rendered AS WRITTEN, never normalised.** `4.30` stays `4.30`.
///   The classifier highlights it amber but does not rewrite the
///   character. No ellipsis anywhere; lines wrap.
/// - **Zero data loss.** Every raw line renders. Un-classified lines
///   just show un-highlighted.
/// - **Colour grammar matches `WorkoutPreview`** — same tokens
///   (textPrimary, accentAmber, accentAction, statusSuccess).
/// - **No new vocabulary, no custom chrome.** SF Symbols for gutter
///   markers; segmented `Picker` is the parent view's chrome (S2 owns
///   the workout-detail v2 shell); this slice just consumes the raw
///   text and renders it.
///
/// API:
///   - `RawWorkoutTextView(rawText: String)` — the SwiftUI surface.
///     Defaults to a 14pt monospaced font.
///   - `RawWorkoutLineClassifier.highlighted(rawText:)` — the pure
///     helper S2 will reuse for bidirectional linkage (tap a set card
///     → flash the source line).
struct RawWorkoutTextView: View {
    let rawText: String
    var fontSize: CGFloat = 14

    /// Compute the lines once per `rawText` change. Cheap — O(n) over
    /// typically ≤100 lines per workout; regex compilation is module-
    /// level static so it's a no-op per call.
    private var lines: [RawLine] {
        RawWorkoutLineClassifier.highlighted(rawText: rawText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                lineRow(line)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineRow(_ line: RawLine) -> some View {
        if line.kind == .blank {
            Color.clear.frame(height: 10)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                gutterMarker(for: line.kind)
                    .frame(width: 12, alignment: .leading)
                Text(line.attributed)
                    .font(line.kind == .section
                          ? .system(size: max(fontSize - 2, 10), weight: .bold, design: .monospaced)
                          : .system(size: fontSize, design: .monospaced))
                    .foregroundColor(textColor(for: line.kind))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, line.kind == .section ? 8 : 3)
        }
    }

    private func textColor(for kind: RawWorkoutLineClass) -> Color {
        switch kind {
        case .section: return .textFaint
        case .round:   return .accentAmber
        case .note:    return .textMuted
        case .set:     return .textPrimary
        case .blank:   return .clear
        }
    }

    @ViewBuilder
    private func gutterMarker(for kind: RawWorkoutLineClass) -> some View {
        switch kind {
        case .set:
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.textPrimary)
                .frame(width: 8, height: 8)
        case .note:
            // Dashed circle — emulates the JS sketch's dashed circle
            // bullet. SwiftUI has no native dashed-shape primitive,
            // so we draw a circle with a dashed stroke.
            Circle()
                .strokeBorder(Color.textMuted, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 7, height: 7)
        case .section:
            Circle()
                .fill(Color.textFaint)
                .frame(width: 6, height: 6)
        case .round:
            // Diamond — emulates the JS sketch's rotated-square bullet.
            // SF Symbol "diamond.fill" is the platform-native match.
            Image(systemName: "diamond.fill")
                .font(.system(size: 9))
                .foregroundColor(.accentAmber)
        case .blank:
            Color.clear.frame(width: 8, height: 8)
        }
    }
}

#Preview("real-input-1 (Squad A — FBBF skills)") {
    ScrollView {
        VStack(spacing: 0) {
            Text("As written")
                .font(.eyebrow)
                .foregroundColor(.textFaint)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            RawWorkoutTextView(rawText: """
            Float high Body position first, feet on lane rope and hands on board or noodle or lane rope- breath control- arms straight

            400 kick for body/head position 100 free 100 back - floppy feet

            3 x 300 FBBF (free,back,breast, free) @ 4:30

            3 x 300 free @ 4.30 as 1.fists/swim, 2. catch up/swim 3. swim

            3 x 200 FBF @ 2:50 by

            3 x 200 free @ 2:50 same as above

            3 x 100 FBFB@ 1.20

            3 x 100 free @1.20 same as above

            30 sec extra rest

            1 x 400 FBFB

            fast for time
            """)
        }
    }
    .background(Color.bgBase)
}