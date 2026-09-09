import SwiftUI

/// WaveChipStrip — V0.54 S3 (2026-09-09): the one-tap-swap lane chip
/// strip rendered above the first rep's stopwatch (spec §3, decision
/// 11). The chip strip is the WAVE chip surface, not the LIVE/BETWEEN
/// CTA. It is a single-tap affordance for lane swaps — no drag-drop
/// (spec §11: "the wave chip strip is one-tap-swap. No drag-and-drop").
///
/// Visibility gate (spec §8, R8): hidden when `roster.count == 1` —
/// a solo swimmer has 1 wave_assignment row and tapping its only
/// chip would surface an empty swap menu.
///
/// Tap behaviour (spec §3): tap a chip → quick-action menu with the
/// OTHER lanes' names. Tap a name → swap the two lanes' wave_assignment
/// rows. One swap per tap. The VM (`SessionConsoleViewModel.swapLanes`)
/// holds the write; this view is presentational.
///
/// The chip strip is a sibling of the stopwatch, not a replacement —
/// the stopwatch below remains the single primary action per spec
/// invariant ("one primary CTA per Console state"). Wave swaps are
/// read as a secondary coach action and styled accordingly.
struct WaveChipStrip: View {
    /// One chip per lane (ordered by lane number, 1-indexed).
    /// Each entry carries the swimmer name to display. Hidden when
    /// `lanes.count <= 1` (R8: solo-swimmer suppression).
    let lanes: [LaneChip]
    /// Tap a chip → the chip's Menu surfaces a pick-list of the
    /// OTHER lanes; the coach picks one. `onPickSwap` is invoked
    /// with `(tappedLane, pickedLane)` so the VM can swap the two
    /// lanes' wave_assignment rows in one call.
    let onPickSwap: (_ tappedLane: Int, _ pickedLane: Int) -> Void

    struct LaneChip: Identifiable, Equatable {
        let lane: Int
        let swimmerName: String
        var id: Int { lane }
    }

    var body: some View {
        // R8: hide the strip entirely when there is only one wave.
        // No placeholder, no "1 lane" caption — the chip surface is
        // a no-op for solo swimmers and would just add visual noise.
        if lanes.count > 1 {
            HStack(spacing: 8) {
                ForEach(lanes) { chip in
                    chipView(chip)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Wave lanes — tap a chip to swap")
        }
    }

    /// A single lane chip. The lane number carries the small "lane N"
    /// affordance; the swimmer name is the primary read. Tapping
    /// surfaces a Menu with the OTHER lanes' names so the coach
    /// picks the swap target in two taps.
    @ViewBuilder
    private func chipView(_ chip: LaneChip) -> some View {
        // Menu is a single-tap-then-pick affordance: the chip shows
        // as a "lane chip" and the menu renders the swap targets
        // inline. SwiftUI Menu renders the popover on tap — exactly
        // the spec's "quick-action menu with the other lanes' names".
        Menu {
            ForEach(otherLanes(than: chip.lane)) { other in
                Button {
                    Haptics.tap()
                    onPickSwap(chip.lane, other.lane)
                } label: {
                    Text("Swap with Lane \(other.lane) · \(other.swimmerName)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Lane \(chip.lane)")
                    .font(.captionStrong)
                    .foregroundStyle(Color.textMuted)
                Text(chip.swimmerName)
                    .font(.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.bgSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.divider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Lane \(chip.lane), \(chip.swimmerName). Tap to swap with another lane.")
    }

    private func otherLanes(than lane: Int) -> [LaneChip] {
        lanes.filter { $0.lane != lane }
    }
}

#Preview {
    WaveChipStrip(
        lanes: [
            .init(lane: 1, swimmerName: "Jack"),
            .init(lane: 2, swimmerName: "Ariana"),
            .init(lane: 3, swimmerName: "Sofie"),
            .init(lane: 4, swimmerName: "Liam")
        ],
        onPickSwap: { _, _ in }
    )
    .padding()
    .background(Color.bgBase)
}