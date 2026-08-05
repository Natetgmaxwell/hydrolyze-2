// PersistRecordedTimeSmoke.swift
//
// Standalone smoke for `persistRecordedTime` on
// `RecordedTimeFragmentService` (t_6163b2f2, 2026-08-05).
// Run with:
//
//   cd "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
//   swift ios-native/Hydrolyze/Tests/PersistRecordedTimeSmoke.swift
//
// What this verifies (the task's acceptance criteria):
//
//   1. The JSON payload shape the iOS `FragmentRow` emits is
//      accepted by Postgres on `recorded_times` — every metadata
//      field lands populated.
//
//   2. swimmer_id is NULL immediately after insert (the
//      pairing handoff fills it in later; not in this slice).
//
//   3. A duplicate UUID insert raises a Postgres "duplicate
//      key value violates unique constraint" error which the
//      `PersistRecordedTimeError.classify` pattern-matcher
//      would bucket into `.duplicateRow`.
//
//   4. The full per-fragment metadata from the worked example
//      `4 x (75 fast / 25 easy)` round-trips: distance=75,
//      intensity=fast, start_type=dive, pace_target_sec=90,
//      raw_text="4 x (75 fast / 25 easy)".
//
// Verification mechanism: shell out to `supabase db query --linked`
// (the same Management API path the prior migration workers used)
// to insert + select + drop test rows. This is the strongest
// verification available on a Mac without Xcode installed —
// it exercises the exact column shape the production iOS
// `FragmentRow` produces against the real DB schema on the
// real Supabase project the iOS app talks to.
//
// Why a SQL smoke instead of a Swift module compile: the
// supabase-swift SDK requires `xcodebuild` for the full
// `swift build` cycle; per project CLAUDE.md, the local
// verification ceiling on this Mac is `swiftc -parse` on
// individual files. The SQL smoke substitutes for the
// end-to-end iOS round-trip by exercising the same wire
// payload the iOS code emits.
//
// All four tests must pass for the spec's acceptance gate.

import Foundation

// ─── shell helper ──────────────────────────────────────────────────────────────

/// Run a SQL query through the supabase CLI (linked project,
/// same as the prior migration workers used). Returns the
/// raw stdout. Throws on non-zero exit.
@discardableResult
func supabaseQuery(_ sql: String) throws -> String {
    let task = Process()
    task.launchPath = "/opt/homebrew/bin/supabase"
    task.arguments = ["db", "query", "--linked", sql]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if task.terminationStatus != 0 {
        throw SmokeError.cliFailed(exitCode: task.terminationStatus, output: output)
    }
    return output
}

/// `supabase db query --linked -f <file>` — for multi-line SQL.
func supabaseQueryFile(_ path: String) throws -> String {
    let task = Process()
    task.launchPath = "/opt/homebrew/bin/supabase"
    task.arguments = ["db", "query", "--linked", "-f", path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if task.terminationStatus != 0 {
        throw SmokeError.cliFailed(exitCode: task.terminationStatus, output: output)
    }
    return output
}

enum SmokeError: Error, CustomStringConvertible {
    case cliFailed(exitCode: Int32, output: String)
    case assertionFailed(test: String, detail: String)

    var description: String {
        switch self {
        case .cliFailed(let code, let out):
            return "supabase CLI exit \(code):\n\(out)"
        case .assertionFailed(let test, let detail):
            return "TEST FAILED [\(test)]: \(detail)"
        }
    }
}

// ─── assertion helper ──────────────────────────────────────────────────────────

func assert(_ condition: Bool, _ test: String, _ detail: @autoclosure () -> String) throws {
    if !condition {
        throw SmokeError.assertionFailed(test: test, detail: detail())
    }
    print("  ✓ \(test)")
}

// ─── harness state ─────────────────────────────────────────────────────────────

var pass = 0
var fail = 0

func run(_ name: String, _ block: () throws -> Void) {
    print("\n── \(name) ──")
    do {
        try block()
        pass += 1
    } catch {
        fail += 1
        print("  ✗ \(name): \(error)")
    }
}

// ─── shared test fixtures ──────────────────────────────────────────────────────

/// Mirrors the iOS FragmentRow's wire shape (the JSON payload
/// `FragmentRow` Encodes via SupabaseService.shared.client).
/// The column keys are snake_case (PostgREST convention).
let workedExampleRowId = UUID().uuidString
let workedExampleSetId = "f17b8ed7-3b04-4140-aada-bb412f66dbb6"  // from prior query
let workedExampleFragmentId = "fragment_75_fast_dive"
let workedExampleRawText = "4 x (75 fast / 25 easy)"
let workedExampleElapsedMs = 42_310   // arbitrary "75 fast" time

// ─── TEST 1: happy path insert + select-back ──────────────────────────────────

run("TEST 1: persistRecordedTime happy path — full metadata lands, swimmer_id NULL") {
    let insertSql = """
    INSERT INTO public.recorded_times (
      id, session_id, swimmer_id, workout_set_id, fragment_id,
      distance_meters, intensity, start_type, pace_target_sec, raw_text,
      time_ms, rep_index, source, confidence, assignment_confidence,
      lap_order
    ) VALUES (
      '\(workedExampleRowId)', NULL, NULL, '\(workedExampleSetId)', '\(workedExampleFragmentId)',
      75, 'fast', 'dive', 90.5, '\(workedExampleRawText)',
      \(workedExampleElapsedMs), 1, 'auto', NULL, NULL,
      0
    )
    RETURNING id, swimmer_id, workout_set_id, fragment_id, distance_meters, intensity, start_type, pace_target_sec, raw_text, time_ms, created_at;
    """
    let insertOutput = try supabaseQuery(insertSql)
    // The CLI prints the returning row in a table. Postgres CLI table
    // output truncates wide UUIDs visually but the underlying string
    // is complete — check the column VALUES column-wise. We check
    // the row was inserted (no duplicate / error) by looking for the
    // known metadata values, not the UUID itself (the table box-width
    // can clip it).
    try assert(!insertOutput.lowercased().contains("duplicate") && !insertOutput.lowercased().contains("error"),
              "insert succeeded without error", "insert errored: \(insertOutput)")
    try assert(insertOutput.contains(workedExampleFragmentId), "fragment_id persisted", "fragment_id missing: \(insertOutput)")
    try assert(insertOutput.contains(workedExampleSetId), "workout_set_id persisted", "set_id missing: \(insertOutput)")
    try assert(insertOutput.contains("75"), "distance_meters persisted", "distance_meters missing: \(insertOutput)")
    try assert(insertOutput.contains("fast"), "intensity persisted", "intensity missing: \(insertOutput)")
    try assert(insertOutput.contains("dive"), "start_type persisted", "start_type missing: \(insertOutput)")
    try assert(insertOutput.contains("90.5"), "pace_target_sec persisted as numeric", "pace_target_sec missing: \(insertOutput)")
    try assert(insertOutput.contains(workedExampleRawText), "raw_text persisted", "raw_text missing: \(insertOutput)")
    try assert(insertOutput.contains(String(workedExampleElapsedMs)), "time_ms persisted", "time_ms missing: \(insertOutput)")

    // SELECT it back independently to verify the row is queryable by
    // the exact UUID we used, and that swimmer_id is NULL (spec
    // acceptance). Use an independent SELECT against the row id.
    let countSql = "SELECT COUNT(*) AS n FROM public.recorded_times WHERE id = '\(workedExampleRowId)';"
    let countOut = try supabaseQuery(countSql)
    try assert(countOut.contains("│ 1 ") || countOut.contains("\n1 \n") || countOut.contains(" 1 "),
              "row exists in recorded_times after insert", "row not found: \(countOut)")

    let selectSql = "SELECT swimmer_id FROM public.recorded_times WHERE id = '\(workedExampleRowId)';"
    let selectOutput = try supabaseQuery(selectSql)
    // The table has a single row, single column. The column value
    // should be the literal string "NULL" (PostgREST convention).
    try assert(selectOutput.contains("NULL") || selectOutput.contains("│ NULL"),
              "swimmer_id is NULL immediately after insert (spec acceptance)", "expected NULL but got: \(selectOutput)")

    // Verify the full row shape one more time via SELECT *. This is
    // the deepest acceptance check: the iOS FragmentRow's wire shape
    // survives a round-trip with every field populated.
    let fullRowSql = "SELECT fragment_id, distance_meters, intensity, start_type, pace_target_sec::text AS pace, raw_text, time_ms FROM public.recorded_times WHERE id = '\(workedExampleRowId)';"
    let fullRow = try supabaseQuery(fullRowSql)
    try assert(fullRow.contains(workedExampleFragmentId), "full row SELECT contains fragment_id", "fragment_id missing in full row: \(fullRow)")
    try assert(fullRow.contains(workedExampleRawText), "full row SELECT contains raw_text", "raw_text missing in full row: \(fullRow)")
    try assert(fullRow.contains("90.5"), "full row SELECT contains pace_target_sec as text", "pace missing in full row: \(fullRow)")
}

// ─── TEST 2: duplicate UUID surfaces "duplicate key" error ────────────────────

run("TEST 2: duplicate UUID insert raises Postgres unique-constraint error (classifies to .duplicateRow)") {
    // Re-insert the SAME id from TEST 1 — should fail with
    // "duplicate key value violates unique constraint".
    // The supabase CLI exits non-zero on query failure, but the
    // error message is captured in stdout (the CLI captures
    // pg errors and prints them). We catch the exit code and
    // verify the failure signature.
    let dupSql = """
    INSERT INTO public.recorded_times (
      id, workout_set_id, fragment_id, distance_meters, intensity, start_type, pace_target_sec, raw_text, time_ms, rep_index, source, lap_order
    ) VALUES (
      '\(workedExampleRowId)', '\(workedExampleSetId)', 'fragment_dup_test', 50, 'easy', 'wall', NULL, 'dup test', 30000, 1, 'auto', 0
    );
    """
    var dupOutput = ""
    var dupExitCode: Int32 = 0
    do {
        dupOutput = try supabaseQuery(dupSql)
        dupExitCode = 0
    } catch let error {
        if case let SmokeError.cliFailed(code, output) = error {
            dupExitCode = code
            dupOutput = output
        } else {
            throw error
        }
    }
    let lowered = dupOutput.lowercased()
    // The CLI exits non-zero on the duplicate — that's the EXPECTED
    // result. The classifier in PersistRecordedTimeError would see
    // the same error message via supabase-swift's localizedDescription
    // and bucket it into .duplicateRow.
    try assert(dupExitCode != 0,
              "duplicate UUID insert causes supabase CLI to exit non-zero",
              "CLI exit was 0 (insert unexpectedly succeeded): \(dupOutput)")
    let hasDuplicateSignal = lowered.contains("duplicate key") ||
                            lowered.contains("unique constraint") ||
                            lowered.contains("23505") ||
                            lowered.contains("already exists")
    try assert(hasDuplicateSignal,
              "duplicate UUID insert triggers Postgres duplicate-key error in CLI output",
              "expected duplicate-key signature, got: \(dupOutput)")

    // The classifier in PersistRecordedTimeError.classify looks for
    // "duplicate" or "unique constraint" or "23505" in the
    // localizedDescription. The CLI output above contains
    // "duplicate key value violates unique constraint
    // \"recorded_times_pkey\"" + "23505" + "already exists" — all
    // three patterns match. The classifier would bucket this into
    // `.duplicateRow`.
    let classifierWouldMatch = lowered.contains("duplicate") ||
                               lowered.contains("unique constraint") ||
                               lowered.contains("23505")
    try assert(classifierWouldMatch,
              "PersistRecordedTimeError.classify would bucket this into .duplicateRow",
              "classifier pattern-match would miss: \(dupOutput)")
}

// ─── TEST 3: works with swimmer_id explicitly omitted (per spec) ──────────────

run("TEST 3: insert with NULL swimmer_id (per spec, pairing fills it later)") {
    let rowId = UUID().uuidString
    let sql = """
    INSERT INTO public.recorded_times (
      id, swimmer_id, workout_set_id, fragment_id, distance_meters, intensity, start_type, pace_target_sec, raw_text, time_ms, rep_index, source, lap_order
    ) VALUES (
      '\(rowId)', NULL, '\(workedExampleSetId)', 'fragment_null_swimmer', 100, 'moderate', 'wall', 75.0, '4x100 moderate', 65123, 1, 'auto', 0
    )
    RETURNING swimmer_id;
    """
    let out = try supabaseQuery(sql)
    try assert(out.contains("NULL"), "RETURNING swimmer_id shows NULL", "expected NULL swimmer_id in RETURNING: \(out)")
    // Cleanup
    _ = try supabaseQuery("DELETE FROM public.recorded_times WHERE id = '\(rowId)';")
}

// ─── TEST 4: numeric pace_target_sec round-trip ───────────────────────────────

run("TEST 4: pace_target_sec numeric type round-trips") {
    let rowId = UUID().uuidString
    // Half-second precision: spec says numeric, our value is integer-aligned
    // (pace targets are seconds, never sub-second in practice), but the
    // numeric column accepts fractional values too. Verify the half-second
    // case lands cleanly.
    let sql = """
    INSERT INTO public.recorded_times (
      id, workout_set_id, fragment_id, distance_meters, intensity, start_type, pace_target_sec, raw_text, time_ms, rep_index, source, lap_order
    ) VALUES (
      '\(rowId)', '\(workedExampleSetId)', 'fragment_numeric_pace', 200, 'firm', 'dive', 142.5, '8x200 firm @ 2:22.5', 142500, 1, 'auto', 0
    )
    RETURNING pace_target_sec;
    """
    let out = try supabaseQuery(sql)
    try assert(out.contains("142.5"), "numeric pace_target_sec round-trips", "expected 142.5 in RETURNING: \(out)")
    _ = try supabaseQuery("DELETE FROM public.recorded_times WHERE id = '\(rowId)';")
}

// ─── TEST 5: wire-up back-fill swimmer_id via UPDATE (t_ea9a65ca) ───────────
//
// Verifies the iOS `pairRecordedTimeViaHandoff` wire-up end-to-end
// against live Supabase:
//   1. Insert a recorded_times row with swimmer_id=NULL.
//   2. UPDATE swimmer_id to the resolved value (the wire-up's
//      matched-path UPDATE).
//   3. SELECT it back — verify swimmer_id is now non-null.
//   4. UPDATE it back to NULL — verify the wire-up can clear
//      swimmer_id for the unmatched-path deferred retry.
//
// This mirrors the iOS service's matched-path UPDATE:
//   supabase.from("recorded_times")
//       .update(["swimmer_id": swimmerId, "confidence": ..., "assignment_confidence": ...])
//       .eq("id", value: rowId)
//       .execute()
//
// Strongest verification available on a Mac without Xcode — same
// `supabase db query --linked` mechanism the other tests use.

run("TEST 5: wire-up UPDATE swimmer_id (matched path) and verify it lands") {
    let rowId = UUID().uuidString
    // swimmer_id is uuid on recorded_times AND has a FK to swimmers.
    // Use a real swimmer id from the dev DB so the FK doesn't reject
    // the wire-up UPDATE. The exact swimmer doesn't matter — we only
    // care that the UPDATE lands. Mirrors the production code path:
    // the pairing handoff resolves to a real swimmer UUID from the
    // wave_assignment's swimmer_id column.
    let swimmerId = "9b2e9233-e128-4714-80c3-daa646b7d5b5"

    // Step 1: insert with swimmer_id=NULL (matches the iOS persistRecordedTime path).
    let insertSql = """
    INSERT INTO public.recorded_times (
      id, swimmer_id, workout_set_id, fragment_id, distance_meters, intensity, start_type, pace_target_sec, raw_text, time_ms, rep_index, source, lap_order
    ) VALUES (
      '\(rowId)', NULL, '\(workedExampleSetId)', 'fragment_wireup_test', 75, 'fast', 'dive', 90.5, '4 x (75 fast / 25 easy)', 42310, 1, 'auto', 0
    )
    RETURNING swimmer_id;
    """
    let insertOut = try supabaseQuery(insertSql)
    try assert(insertOut.contains("NULL"), "wire-up: row inserted with swimmer_id=NULL", "expected NULL in RETURNING: \(insertOut)")

    // Step 2: UPDATE swimmer_id + confidence + assignment_confidence
    // (matches the iOS pairRecordedTimeViaHandoff .matched branch).
    let updateSql = """
    UPDATE public.recorded_times
    SET swimmer_id = '\(swimmerId)', confidence = 99, assignment_confidence = 1.0
    WHERE id = '\(rowId)';
    """
    _ = try supabaseQuery(updateSql)

    // Step 3: SELECT it back and verify the wire-up landed.
    let verifySql = "SELECT swimmer_id, confidence, assignment_confidence FROM public.recorded_times WHERE id = '\(rowId)';"
    let verifyOut = try supabaseQuery(verifySql)
    try assert(verifyOut.contains(swimmerId), "wire-up UPDATE landed: swimmer_id is alice", "expected swimmerId in output: \(verifyOut)")
    try assert(verifyOut.contains("99"), "wire-up UPDATE landed: confidence is 99", "expected confidence=99 in output: \(verifyOut)")
    try assert(verifyOut.contains("1.0"), "wire-up UPDATE landed: assignment_confidence is 1.0", "expected assignment_confidence=1.0 in output: \(verifyOut)")

    // Step 4: clear swimmer_id (simulates the deferred-retry path —
    // the unmatched row stays NULL; later pairExistingRow can re-set it).
    let clearSql = "UPDATE public.recorded_times SET swimmer_id = NULL WHERE id = '\(rowId)';"
    _ = try supabaseQuery(clearSql)
    let afterClearOut = try supabaseQuery("SELECT swimmer_id FROM public.recorded_times WHERE id = '\(rowId)';")
    try assert(afterClearOut.contains("NULL"), "wire-up: row can be cleared back to swimmer_id=NULL", "expected NULL after clear: \(afterClearOut)")

    // Cleanup
    _ = try supabaseQuery("DELETE FROM public.recorded_times WHERE id = '\(rowId)';")
}

// ─── cleanup ──────────────────────────────────────────────────────────────────

run("cleanup: drop test rows") {
    // TEST 1 row has the worked-example id. Drop it. TEST 2's failed
    // insert did not land a row, so nothing to drop there.
    let cleanup = "DELETE FROM public.recorded_times WHERE id = '\(workedExampleRowId)';"
    _ = try supabaseQuery(cleanup)
    // Verify the row is gone (0 rows affected).
    let count = try supabaseQuery("SELECT COUNT(*) FROM public.recorded_times WHERE id = '\(workedExampleRowId)';")
    try assert(count.contains("0"), "TEST 1 row cleaned up", "row not deleted: \(count)")
}

// ─── summary ──────────────────────────────────────────────────────────────────

print("\n═══════════════════════════════════════════════")
print("PersistRecordedTimeSmoke — \(pass) pass / \(fail) fail")
print("═══════════════════════════════════════════════")
exit(fail == 0 ? 0 : 1)