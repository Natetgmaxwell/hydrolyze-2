import Foundation

func createScenarios() -> [Scenario] {
    var scenarios = [Scenario]()
    
    // 1. Clean 5-swimmer race
    // A, B, C, D, E doing 100m Free at race pace.
    let t0 = 0.0
    scenarios.append(Scenario(
        name: "Clean 5-swimmer race",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!, SWIMMERS_DICT["C"]!, SWIMMERS_DICT["D"]!, SWIMMERS_DICT["E"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 58600), // A: 58500
            Tap(id: "T2", timeMs: t0 + 62500), // B: 62300
            Tap(id: "T3", timeMs: t0 + 65600), // C: 65800
            Tap(id: "T4", timeMs: t0 + 70000), // D: 69500
            Tap(id: "T5", timeMs: t0 + 74000)  // E: 74200
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "B"),
            GroundTruth(tapId: "T3", swimmerId: "C"),
            GroundTruth(tapId: "T4", swimmerId: "D"),
            GroundTruth(tapId: "T5", swimmerId: "E")
        ]
    ))
    
    // 2. Realistic variance (0.3-3s off PB)
    scenarios.append(Scenario(
        name: "Realistic variance",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!, SWIMMERS_DICT["C"]!, SWIMMERS_DICT["D"]!, SWIMMERS_DICT["E"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 58500 + 300),
            Tap(id: "T2", timeMs: t0 + 62300 - 400),
            Tap(id: "T3", timeMs: t0 + 65800 + 1500),
            Tap(id: "T4", timeMs: t0 + 69500 + 2500),
            Tap(id: "T5", timeMs: t0 + 74200 - 3000) // E is 3s faster
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "B"),
            GroundTruth(tapId: "T3", swimmerId: "C"),
            GroundTruth(tapId: "T4", swimmerId: "D"),
            GroundTruth(tapId: "T5", swimmerId: "E")
        ]
    ))
    
    // 3. Missed tap
    scenarios.append(Scenario(
        name: "Missed tap",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!, SWIMMERS_DICT["C"]!, SWIMMERS_DICT["D"]!, SWIMMERS_DICT["E"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 58600), // A
            Tap(id: "T2", timeMs: t0 + 65600), // C (B missed)
            Tap(id: "T3", timeMs: t0 + 70000), // D
            Tap(id: "T4", timeMs: t0 + 74000)  // E
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "C"),
            GroundTruth(tapId: "T3", swimmerId: "D"),
            GroundTruth(tapId: "T4", swimmerId: "E")
        ]
    ))
    
    // 4. Double tap (phantom)
    scenarios.append(Scenario(
        name: "Double tap (phantom)",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!, SWIMMERS_DICT["C"]!, SWIMMERS_DICT["D"]!, SWIMMERS_DICT["E"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 58600), // A
            Tap(id: "T2", timeMs: t0 + 62500), // B
            Tap(id: "T3", timeMs: t0 + 62700), // Phantom
            Tap(id: "T4", timeMs: t0 + 65600), // C
            Tap(id: "T5", timeMs: t0 + 70000), // D
            Tap(id: "T6", timeMs: t0 + 74000)  // E
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "B"),
            GroundTruth(tapId: "T3", swimmerId: nil), // Ghost
            GroundTruth(tapId: "T4", swimmerId: "C"),
            GroundTruth(tapId: "T5", swimmerId: "D"),
            GroundTruth(tapId: "T6", swimmerId: "E")
        ]
    ))
    
    // 5. Tight pack
    scenarios.append(Scenario(
        name: "Tight pack",
        swimmers: [SWIMMERS_DICT["B"]!, SWIMMERS_DICT["C"]!, SWIMMERS_DICT["D"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 65000),
            Tap(id: "T2", timeMs: t0 + 65200),
            Tap(id: "T3", timeMs: t0 + 65400)
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "B"), // B normally 62.3, C normally 65.8, D normally 69.5
            GroundTruth(tapId: "T2", swimmerId: "C"), // Assuming they finished B, C, D in this tight pack
            GroundTruth(tapId: "T3", swimmerId: "D")
        ]
    ))
    
    // 6. Cold start swimmer (F has no PB)
    scenarios.append(Scenario(
        name: "Cold start swimmer",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!, SWIMMERS_DICT["F"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 58600), // A
            Tap(id: "T2", timeMs: t0 + 62500), // B
            Tap(id: "T3", timeMs: t0 + 80000)  // F finishes at 80s
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "B"),
            GroundTruth(tapId: "T3", swimmerId: "F")
        ]
    ))
    
    // 7. Multi-rep fatigue
    scenarios.append(Scenario(
        name: "Multi-rep fatigue",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "moderate", repIndex: 4), // 5th rep
        waveStartTimeMs: t0,
        // Fatigue adds up. Int mod = 1.10. Rep 4 fatigue = +2%. Total expected = PB * 1.10 * 1.02.
        // A PB 58.5 * 1.10 * 1.02 = 65.637
        // B PB 62.3 * 1.10 * 1.02 = 69.900
        taps: [
            Tap(id: "T1", timeMs: t0 + 65600),
            Tap(id: "T2", timeMs: t0 + 69900)
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "B")
        ]
    ))
    
    // 8. Wrong intensity
    scenarios.append(Scenario(
        name: "Wrong intensity",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        // But swimming easy (1.25)
        // A: 58.5 * 1.25 = 73.125
        // B: 62.3 * 1.25 = 77.875
        taps: [
            Tap(id: "T1", timeMs: t0 + 73000),
            Tap(id: "T2", timeMs: t0 + 78000)
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "B")
        ]
    ))
    
    // 9. Mixed ability
    scenarios.append(Scenario(
        name: "Mixed ability",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["E"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 58000),
            Tap(id: "T2", timeMs: t0 + 75000)
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "A"),
            GroundTruth(tapId: "T2", swimmerId: "E")
        ]
    ))
    
    // 10. Large wave
    scenarios.append(Scenario(
        name: "Large wave",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!, SWIMMERS_DICT["C"]!, SWIMMERS_DICT["D"]!, SWIMMERS_DICT["E"]!, SWIMMERS_DICT["G"]!, SWIMMERS_DICT["H"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        // H has Breast PB 72000, G has 50m Free PB 27500 (Riegel 100m Free: 27500 * (100/50)^1.03 = 56162)
        // A: 58.5, B: 62.3, C: 65.8, D: 69.5, E: 74.2
        taps: [
            Tap(id: "T1", timeMs: t0 + 56000), // G
            Tap(id: "T2", timeMs: t0 + 58500), // A
            Tap(id: "T3", timeMs: t0 + 62000), // B
            Tap(id: "T4", timeMs: t0 + 66000), // C
            Tap(id: "T5", timeMs: t0 + 69500), // D
            Tap(id: "T6", timeMs: t0 + 72500), // H
            Tap(id: "T7", timeMs: t0 + 74000)  // E
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "G"),
            GroundTruth(tapId: "T2", swimmerId: "A"),
            GroundTruth(tapId: "T3", swimmerId: "B"),
            GroundTruth(tapId: "T4", swimmerId: "C"),
            GroundTruth(tapId: "T5", swimmerId: "D"),
            GroundTruth(tapId: "T6", swimmerId: "H"),
            GroundTruth(tapId: "T7", swimmerId: "E")
        ]
    ))
    
    // 11. Two swimmers with near-identical PBs
    let swimmerB_clone = Swimmer(id: "B2", name: "Bob2", pbs: ["100_Free": 62400], baseSigma: 800)
    scenarios.append(Scenario(
        name: "Two swimmers near-identical PBs",
        swimmers: [SWIMMERS_DICT["B"]!, swimmerB_clone],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 62350),
            Tap(id: "T2", timeMs: t0 + 62600)
        ],
        groundTruth: [
            GroundTruth(tapId: "T1", swimmerId: "B"),
            GroundTruth(tapId: "T2", swimmerId: "B2")
        ]
    ))
    
    // 12. Massive outlier day
    scenarios.append(Scenario(
        name: "Massive outlier day",
        swimmers: [SWIMMERS_DICT["A"]!, SWIMMERS_DICT["B"]!],
        setInfo: SetInfo(distance: 100, stroke: "Free", intensity: "race", repIndex: 0),
        waveStartTimeMs: t0,
        taps: [
            Tap(id: "T1", timeMs: t0 + 66500), // A is 8 seconds off PB!
            Tap(id: "T2", timeMs: t0 + 62500)  // B is normal
        ],
        groundTruth: [
            GroundTruth(tapId: "T2", swimmerId: "B"), // Ordered by time
            GroundTruth(tapId: "T1", swimmerId: "A")
        ]
    ))

    return scenarios
}
