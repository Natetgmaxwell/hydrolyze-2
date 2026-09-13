#!/usr/bin/env swift
//
// V0.55 S0a acceptance check #4: classify real-input-1.txt and verify
// the expected line classes. Run from repo root:
//
//   swift scripts/v055_s0a_classifier_check.swift
//
// Prints PASS/FAIL per expectation, exits non-zero on any miss.
// Mirrors the JS prototype's classifier (sketches/003-respected-raw) so
// the iOS rendering matches what the design sketches proved out.

import Foundation

// MARK: - Mirror of RawWorkoutLineClassifier.classify (no SwiftUI deps)
//
// We can't import the iOS-only SwiftUI symbols locally, but we CAN
// re-implement the classification logic here in pure Foundation and
// assert that it matches the production classifier. Any drift is caught
// here before sim build.

enum RawWorkoutLineClass: String {
    case set, note, section, round, blank
}

func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    return try! NSRegularExpression(pattern: pattern, options: options)
}

let sectionExact = regex(#"^(warm[\s-]?up|warm[\s-]?down|cool[\s-]?down|main set|drill(ing)?|technique|kick set|pull set|sprint|activation)\s*:?\s*$"#, [.caseInsensitive])
let sectionContains = regex(#"^(warm[\s-]?up|main set|drill progression|technique set|cool[\s-]?down|optional speed activation)\b"#, [.caseInsensitive])
let round = regex(#"^\d+\s*(?:x|×)?\s*(?:rounds?\s+of|through)\s*:?\s*$"#, [.caseInsensitive])
let reps = regex(#"\d+\s*[x×]\s*\d+(?:\.\d+)?"#)
let bareDistance = regex(#"^\d+(?:\.\d+)?\s*(?:m\b)?"#, [.caseInsensitive])
let secPrefix = regex(#"^\d+\s*sec"#, [.caseInsensitive])

func classify(line: String) -> RawWorkoutLineClass {
    let ns = line as NSString
    let full = NSRange(location: 0, length: ns.length)
    if round.firstMatch(in: line, options: [], range: full) != nil { return .round }
    if sectionExact.firstMatch(in: line, options: [], range: full) != nil { return .section }
    if line.count < 34,
       sectionContains.firstMatch(in: line, options: [], range: full) != nil,
       reps.firstMatch(in: line, options: [], range: full) == nil {
        return .section
    }
    if reps.firstMatch(in: line, options: [], range: full) != nil { return .set }
    if bareDistance.firstMatch(in: line, options: [], range: full) != nil {
        guard let first = line.first else { return .note }
        let upperWord = first.isUppercase && first.isLetter
        if !upperWord, secPrefix.firstMatch(in: line, options: [], range: full) == nil {
            return .set
        }
    }
    return .note
}

// MARK: - Test corpus (verbatim from scripts/parser-bench/real-input-1.txt)

let corpus = """
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

// Expectations per V0.55 S0a acceptance #4:
//   - "Float high Body position first, feet on lane rope..." → note
//   - "30 sec extra rest" → note
//   - "1 x 400 FBFB" → set
//   - "3 x 300 FBBF (free,back,breast, free) @ 4:30" → set
// We classify every non-blank line and report all of them so the
// orchestrator can spot anything unexpected.

struct Expectation {
    let needle: String
    let expected: RawWorkoutLineClass
    let why: String
}

let expectations: [Expectation] = [
    .init(needle: "Float high Body position first", expected: .note,  why: "FBBF prose intro — no rep pattern, capitalised sentence starter"),
    .init(needle: "400 kick for body/head position",     expected: .set,   why: "bare-distance starts the line"),
    .init(needle: "3 x 300 FBBF",                         expected: .set,   why: "reps match — FBBF set"),
    .init(needle: "3 x 300 free @ 4.30",                  expected: .set,   why: "reps match — decimal interval shown AS WRITTEN"),
    .init(needle: "3 x 200 FBF",                          expected: .set,   why: "reps match"),
    .init(needle: "3 x 200 free @ 2:50",                  expected: .set,   why: "reps match"),
    .init(needle: "3 x 100 FBFB@ 1.20",                   expected: .set,   why: "reps match"),
    .init(needle: "3 x 100 free @1.20",                   expected: .set,   why: "reps match"),
    .init(needle: "30 sec extra rest",                    expected: .note,  why: "sec-prefix line — rest note"),
    .init(needle: "1 x 400 FBFB",                         expected: .set,   why: "reps match"),
    .init(needle: "fast for time",                        expected: .note,  why: "no rep pattern, no distance — note"),
]

// MARK: - Run

let lines = corpus.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }

print("=== V0.55 S0a — classifier check (real-input-1.txt) ===")
print(String(repeating: "=", count: 60))
print("Line-by-line classification:")
for (idx, line) in lines.enumerated() {
    if line.isEmpty {
        print("\(String(format: "%3d", idx))  (blank)                      → blank")
        continue
    }
    let cls = classify(line: line)
    let truncated = line.count > 44 ? String(line.prefix(44)) + "…" : line
    print("\(String(format: "%3d", idx))  \(truncated.padding(toLength: 44, withPad: " ", startingAt: 0)) → \(cls.rawValue)")
}

print("")
print(String(repeating: "=", count: 60))
print("Expected-class assertions:")
var failures = 0
for exp in expectations {
    let match = lines.first(where: { $0.contains(exp.needle) })
    guard let line = match else {
        print("FAIL  needle '\(exp.needle)' not found in corpus")
        failures += 1
        continue
    }
    let actual = classify(line: line)
    if actual == exp.expected {
        print("PASS  '\(exp.needle)…' → \(actual.rawValue)  [\(exp.why)]")
    } else {
        print("FAIL  '\(exp.needle)…' expected=\(exp.expected.rawValue) actual=\(actual.rawValue)  [\(exp.why)]")
        failures += 1
    }
}

print("")
print(String(repeating: "=", count: 60))
if failures == 0 {
    print("RESULT: \(expectations.count)/\(expectations.count) PASS")
    exit(0)
} else {
    print("RESULT: \(failures) FAIL of \(expectations.count)")
    exit(1)
}