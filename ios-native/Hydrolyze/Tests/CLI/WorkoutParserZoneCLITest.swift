// V0.41 Slice 1 — CLI test for zone_term extraction in WorkoutParser.
// Mirrors scripts/parser-bench/real-input-21.txt case-for-case so the
// on-device parser and the edge parser provably agree on the four zone
// words.
//
// Exit 0 = all cases pass. Non-zero = zone-term divergence.

import Foundation

@main
struct WorkoutParserZoneCLITest {
    static func main() {
        var pass = 0
        var fail = 0

        func repGroups(_ input: String) -> [ParsedRepGroup] {
            WorkoutParser.parse(input).sections.flatMap { $0.namedSets.flatMap { $0.repGroups } }
        }

        func check(
            _ name: String,
            _ input: String,
            idx: Int,
            expectedZone: String?,
            reps: Int?,
            distance: Int?
        ) {
            let rgs = repGroups(input)
            guard rgs.indices.contains(idx) else {
                print("FAIL \(name): no repGroup at index \(idx) (got \(rgs.count))")
                fail += 1
                return
            }
            let rg = rgs[idx]
            let ok =
                rg.zoneTerm == expectedZone &&
                (reps == nil || rg.reps == reps) &&
                (distance == nil || rg.distance == distance)
            if ok {
                print("PASS \(name): zoneTerm=\(rg.zoneTerm ?? "nil") reps=\(rg.reps ?? -1) dist=\(rg.distance ?? -1)")
                pass += 1
            } else {
                print("FAIL \(name): expected zoneTerm=\(expectedZone ?? "nil"), got \(rg.zoneTerm ?? "nil")")
                fail += 1
            }
        }

        // Positive zone cases (mirror real-input-21.txt).
        check("8x100 Steady", "8×100 Steady on 1:30", idx: 0, expectedZone: "steady", reps: 8, distance: 100)
        check("4x50 Sprint", "4×50 Sprint", idx: 0, expectedZone: "sprint", reps: 4, distance: 50)
        check("8x100 free (no zone)", "8×100 free on 1:30", idx: 0, expectedZone: nil, reps: 8, distance: 100)
        check("4x100 Hard", "4×100 Hard", idx: 0, expectedZone: "hard", reps: 4, distance: 100)

        // easy zone term.
        check("8x100 Easy", "8×100 Easy on 1:30", idx: 0, expectedZone: "easy", reps: 8, distance: 100)

        // Composite set with two zone words → nil at set level
        // (fragments carry per-segment intensity).
        check("composite fast/easy → nil", "8×100 (75 Steady / 25 easy)", idx: 0, expectedZone: nil, reps: 8, distance: 100)

        // 3MT never yields a zone term.
        let threeMT = repGroups("3MT free")
        if let rg = threeMT.first, rg.zoneTerm == nil, rg.intensity?.type.rawValue == "3mt" {
            print("PASS 3MT zoneTerm nil")
            pass += 1
        } else {
            print("FAIL 3MT zoneTerm: \(threeMT.first?.zoneTerm ?? "nil")")
            fail += 1
        }

        print("")
        print("\(pass) pass, \(fail) fail")
        exit(fail > 0 ? 1 : 0)
    }
}
