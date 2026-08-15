// V0.38 Slice 3 — CLI test for 3MT recognition in WorkoutParser.
// Mirrors scripts/parser-bench/_3mt_check.ts case-for-case so the
// on-device parser and the edge parser provably agree.
//
// Exit 0 = all cases pass. Non-zero = recognition divergence between
// the Swift parser and the spec.

import Foundation

@main
struct WorkoutParser3MTCLITest {
    static func main() {
        var pass = 0
        var fail = 0

        func check(
            _ name: String,
            _ input: String,
            idx: Int,
            reps: Int,
            distance: Int,
            intensityType: String,
            intervalNil: Bool = true,
            stroke: String? = nil
        ) {
            let parsed = WorkoutParser.parse(input)
            let rgs = parsed.sections.flatMap { $0.namedSets.flatMap { $0.repGroups } }
            guard rgs.indices.contains(idx) else {
                print("FAIL \(name): no repGroup at index \(idx) (got \(rgs.count))")
                fail += 1
                return
            }
            let rg = rgs[idx]
            let ok =
                rg.reps == reps &&
                rg.distance == distance &&
                rg.intensity?.type.rawValue == intensityType &&
                (!intervalNil || rg.interval == nil) &&
                (stroke == nil || rg.stroke == stroke)
            if ok {
                print("PASS \(name): reps=\(rg.reps ?? -1) dist=\(rg.distance ?? -1) stroke=\(rg.stroke ?? "nil") intensity=\(rg.intensity?.type.rawValue ?? "nil")")
                pass += 1
            } else {
                print("FAIL \(name): expected reps=\(reps) dist=\(distance) intensity=\(intensityType) stroke=\(stroke ?? "any"), got reps=\(rg.reps.map(String.init) ?? "nil") dist=\(rg.distance.map(String.init) ?? "nil") intensity=\(rg.intensity?.type.rawValue ?? "nil") stroke=\(rg.stroke ?? "nil")")
                fail += 1
            }
        }

        // Positive cases — all markers, with and without stroke words.
        check("bare 3MT", "200 easy\n3MT\n4 x 50 kick", idx: 1, reps: 1, distance: 25, intensityType: "3mt")
        check("3MT free", "3MT free", idx: 0, reps: 1, distance: 25, intensityType: "3mt", stroke: "Free")
        check("3-min all-out", "3-min all-out", idx: 0, reps: 1, distance: 25, intensityType: "3mt")
        check("3 min test", "3 min test", idx: 0, reps: 1, distance: 25, intensityType: "3mt")
        check("3-minute all-out kick", "3-minute all-out kick", idx: 0, reps: 1, distance: 25, intensityType: "3mt", stroke: "Kick")
        check("3-MT", "3-MT", idx: 0, reps: 1, distance: 25, intensityType: "3mt")

        // Neighbors unaffected.
        let mixed = WorkoutParser.parse("200 easy\n3MT\n4 x 50 kick @ 1:00")
        let mixedRgs = mixed.sections.flatMap { $0.namedSets.flatMap { $0.repGroups } }
        if mixedRgs.count == 3,
           mixedRgs[0].reps == 1, mixedRgs[0].distance == 200,
           mixedRgs[1].reps == 1, mixedRgs[1].distance == 25, mixedRgs[1].intensity?.type.rawValue == "3mt",
           mixedRgs[2].reps == 4, mixedRgs[2].distance == 50, mixedRgs[2].intensity?.type.rawValue != "3mt" {
            print("PASS mixed neighbors unaffected")
            pass += 1
        } else {
            print("FAIL mixed neighbors: \(mixedRgs.map { "\($0.reps ?? -1)x\($0.distance ?? -1) \($0.intensity?.type.rawValue ?? "nil")" })")
            fail += 1
        }

        // Normal workout never trips 3MT.
        let normal = WorkoutParser.parse("8 x 100 free @ 1:30\n4 x 50 max\n3 x 200 pull")
        let normalRgs = normal.sections.flatMap { $0.namedSets.flatMap { $0.repGroups } }
        if normalRgs.count == 3, normalRgs.allSatisfy({ $0.intensity?.type.rawValue != "3mt" }) {
            print("PASS normal workout unaffected")
            pass += 1
        } else {
            print("FAIL normal workout affected: \(normalRgs.map { $0.intensity?.type.rawValue ?? "nil" })")
            fail += 1
        }

        // is3MT helper: true iff a 3MT repGroup exists.
        let threeMTWorkout = WorkoutParser.parse("200 easy\n3MT\n4 x 50 kick")
        let trainingWorkout = WorkoutParser.parse("8 x 100 free @ 1:30")
        if WorkoutParser.is3MT(threeMTWorkout) && !WorkoutParser.is3MT(trainingWorkout) {
            print("PASS is3MT helper")
            pass += 1
        } else {
            print("FAIL is3MT helper: 3mt-workout=\(WorkoutParser.is3MT(threeMTWorkout)) training=\(WorkoutParser.is3MT(trainingWorkout))")
            fail += 1
        }

        print("")
        print("\(pass) pass, \(fail) fail")
        exit(fail > 0 ? 1 : 0)
    }
}
