import SwiftUI

/// V0.55 S0a verification harness — a standalone app rendering
/// `RawWorkoutTextView` with `real-input-1.txt`'s FBBF corpus. Built
/// as a separate iOS app target so we can capture a screenshot of
/// the actual SwiftUI render (with AttributedString highlighting and
/// the gutter bullets) without needing the full Hydrolyze app's
/// login flow.
///
/// This file is **not** shipped to production. It lives outside the
/// `Hydrolyze/Sources` tree so xcodegen won't pick it up; it's added
/// to the verification `project.yml` only when the orchestrator
/// wants a screenshot. The same `RawWorkoutLineClassifier` and
/// `RawWorkoutTextView` symbols are compiled in via a `path:` glob
/// so the screenshot reflects the production code path.

@main
struct RawWorkoutScreenshotApp: App {
    var body: some Scene {
        WindowGroup {
            // No ScrollView — VStack fills the screen and lets
            // SwiftUI shrink the content to fit. With a 12pt mono
            // font and 3pt vertical padding, 22 lines + 5 blanks
            // (~10pt each) fit comfortably in iPhone 15 Pro's
            // 852pt height.
            VStack(alignment: .leading, spacing: 0) {
                Text("V0.55 S0a — As written (real-input-1.txt)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.56, green: 0.69, blue: 0.71))
                    .tracking(1.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                RawWorkoutTextView(rawText: rawInput1, fontSize: 12)
                    .background(Color(red: 0.03, green: 0.19, blue: 0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.03, green: 0.19, blue: 0.20).ignoresSafeArea())
        }
    }
}

private let rawInput1 = """
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
"""