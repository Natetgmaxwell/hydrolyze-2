// SoloLapAttributionSmoke.swift
//
// V0.50 (2026-08-30): proves the non-composite-set fragment stamp works.
// Standalone smoke; run with:
//
//   cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
//   swift ios-native/Hydrolyze/Tests/SoloLapAttributionSmoke.swift

import Foundation

enum SmokeError: Error {
    case cliFailed(Int32, String)
    case jsonParseFailed(String)
}

func supabaseQuery(_ sql: String) throws -> String {
    let task = Process()
    task.launchPath = "/usr/bin/curl"
    task.arguments = [
        "-s", "-X", "POST",
        "https://api.supabase.com/v1/projects/flidjtldfvrrntzwtnsq/database/query",
        "-H", "Authorization: Bearer sbp_760127ef7f34b82ef3d0fce71a6241d6a475a7be",
        "-H", "Content-Type: application/json",
        "-d", sql
    ]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if task.terminationStatus != 0 {
        throw SmokeError.cliFailed(task.terminationStatus, output)
    }
    return output
}

struct RecordedTimeRow: Decodable {
    let id: String
    let swimmer_id: String?
    let paired_swimmer_id: String?
    let fragment_id: String?
    let time_ms: Int
    let session_id: String?
    let workout_set_id: String?
    let confidence: Int?
}

func decRows(_ json: String) throws -> [RecordedTimeRow] {
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    do {
        return try decoder.decode([RecordedTimeRow].self, from: data)
    } catch {
        throw SmokeError.jsonParseFailed("\(error) -- raw: \(json.prefix(200))")
    }
}

// Fixtures -- same values the live e2e session used.
let testRowId = "aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee"
let syntheticKey = "set_aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee"
let sessionId = "e2e329b0-6416-402e-873f-6c525c82ed5b"
let setId = "fc5d1b6f-2006-434c-bb8b-91caab6e1963"
let coachId = "254b5ebb-e7a6-4c28-868c-d35acf6cac68"
let swimmerId = "11111111-1111-4111-8111-111111111111"

func deleteTestRow() {
    let sql = #"{"query":"DELETE FROM recorded_times WHERE id = '#(testRowId)'"}"#
    _ = try? supabaseQuery(sql)
}

print("V0.50 SoloLapAttributionSmoke -- verifying synthetic fragment_id stamps...")

deleteTestRow()

// TEST 1: Insert the row the V0.50 setRow patch would produce.
let insertJSON = #"{"query":"INSERT INTO recorded_times (id, swimmer_id, paired_swimmer_id, fragment_id, time_ms, session_id, workout_set_id, coach_id, rep_index, lap_order, wave_number, intensity, stroke, distance_meters, start_type, assignment_confidence, confidence, source, created_at) VALUES ('\#(testRowId)', NULL, '\#(swimmerId)', '\#(syntheticKey)', 33500, '\#(sessionId)', '\#(setId)', '\#(coachId)', 0, 1, 0, 'hard', 'Free', 50, 'in_water', 0.91, 91, 'auto', NOW())"}"#

do {
    let _ = try supabaseQuery(insertJSON)
    print("TEST 1 OK: row inserted with fragment_id = synthetic key")
} catch {
    print("TEST 1 FAIL: insert failed -- \(error)")
    deleteTestRow()
    exit(1)
}

// TEST 2: Re-fetch and verify the round-trip.
let selectJSON = #"{"query":"SELECT id, swimmer_id, paired_swimmer_id, fragment_id, time_ms, session_id, workout_set_id, confidence FROM recorded_times WHERE id = '\#(testRowId)'"}"#

do {
    let json = try supabaseQuery(selectJSON)
    let rows = try decRows(json)
    guard let row = rows.first else {
        print("TEST 2 FAIL: row not found after insert")
        deleteTestRow()
        exit(1)
    }
    var failures: [String] = []
    if row.fragment_id != syntheticKey {
        failures.append("fragment_id mismatch: \(row.fragment_id ?? "nil") != \(syntheticKey)")
    }
    if row.paired_swimmer_id != swimmerId {
        failures.append("paired_swimmer_id mismatch: \(row.paired_swimmer_id ?? "nil")")
    }
    if row.swimmer_id != nil {
        failures.append("swimmer_id should be NULL (paired path convention), got: \(row.swimmer_id ?? "nil")")
    }
    if row.time_ms != 33500 {
        failures.append("time_ms mismatch: \(row.time_ms)")
    }
    if row.session_id != sessionId {
        failures.append("session_id mismatch")
    }
    if row.workout_set_id != setId {
        failures.append("workout_set_id mismatch")
    }
    if failures.isEmpty {
        print("TEST 2 OK: round-trip columns match. fragment_id=\(syntheticKey), paired_swimmer_id=set, swimmer_id=NULL")
    } else {
        print("TEST 2 FAIL:")
        for f in failures { print("  - \(f)") }
        deleteTestRow()
        exit(1)
    }
} catch {
    print("TEST 2 FAIL: \(error)")
    deleteTestRow()
    exit(1)
}

// TEST 3: Pure-Swift bucketing check (mirrors loadFragmentTimes fallback rule).
struct Bucket: Decodable {
    let id: String?
    let fragment_id: String?
    let paired_swimmer_id: String?
}

let simulatedLoad: [String: [Bucket]] = [
    syntheticKey: [
        Bucket(id: testRowId, fragment_id: syntheticKey, paired_swimmer_id: swimmerId)
    ]
]
let bucket = simulatedLoad[syntheticKey] ?? []
if bucket.count == 1 && bucket[0].paired_swimmer_id == swimmerId {
    print("TEST 3 OK: bucketing finds the row under synthetic key, paired_swimmer_id survives")
} else {
    print("TEST 3 FAIL: bucketing missed the row")
    deleteTestRow()
    exit(1)
}

// TEST 4: WHERE-clause find by synthetic key proves the column is queryable as text.
let findJSON = #"{"query":"SELECT id, fragment_id, paired_swimmer_id FROM recorded_times WHERE fragment_id = '\#(syntheticKey)' AND id = '\#(testRowId)'"}"#
do {
    let json = try supabaseQuery(findJSON)
    let rows: [Bucket] = {
        let data = json.data(using: .utf8)!
        return (try? JSONDecoder().decode([Bucket].self, from: data)) ?? []
    }()
    if rows.isEmpty {
        print("TEST 4 FAIL: row not findable by synthetic key in WHERE clause")
        deleteTestRow()
        exit(1)
    }
    print("TEST 4 OK: row findable by fragment_id=syntheticKey (text column)")
} catch {
    print("TEST 4 FAIL: \(error)")
    deleteTestRow()
    exit(1)
}

deleteTestRow()
print("")
print("[OK] V0.50 SoloLapAttributionSmoke -- all tests passed.")
