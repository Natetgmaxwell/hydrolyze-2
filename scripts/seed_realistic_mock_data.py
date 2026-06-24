#!/usr/bin/env python3
"""
seed_realistic_mock_data.py — v2.0 seeder for Hydrolyze swimmer data.

PHASE 2 (Analytics): v2.0 modifications for the Analytics tab.

CHANGES FROM v1.15:
1. PHASES: anchored to NOW (last 6 weeks) instead of the v1.15
   hardcoded Dec 2025 → Apr 2026 dates. v1.15 data landed outside
   the v2.0 analytics 6-week trend window, so the Analytics tab
   showed "Insufficient data" for every swimmer.
2. Session generation: 6 weeks × 2 sessions/week = 12 sessions
   (was 4 months × 2 sessions/week = 32 sessions in v1.15).
3. PB generation: collapsed from 4 intensity variants per
   (swimmer, stroke, distance) combo to 1 (the race PB at
   intensity='max'). The v1.15 attempt to insert 4 intensity
   variants per combo blew up on the
   `swimmer_pbs_swimmer_stroke_distance_gear_key` UNIQUE
   constraint, which doesn't include intensity. v2.0 inserts
   just the race PB; the intensity variants can be added back
   when the schema is upgraded to include intensity in the
   UNIQUE key (separate migration, post-Phase 2).
4. Edge case PBs: shifted to NOW (was 2026-01-01 and
   2026-04-15 hardcoded).
5. Workouts: scheduled_at now derived from the first session's
   started_at date so the Today tab doesn't show "No workout
   scheduled" (was hardcoded 2025-12-15).
6. New helper: sessions_meta threaded through `data` so the
   workout scheduling logic can read the first session's
   started_at. Fixes NameError on the initial run.

PRE-SEED CLEANUP (run before this seeder):
  /tmp/cleanup_test_data.sql wipes all coach-scoped data
  (recorded_times, swimmer_pbs, sessions, workout_sets,
  workouts, calibration tables) so this seeder can run
  cleanly without duplicate-key violations. The cleanup is
  idempotent and coach-scoped via the v1.15 COACH_ID.

VERIFIED POST-SEED STATE (run 2026-06-23):
  swimmers: 14 (8 existing + 6 new)
  recorded_times: 432 (was 1,414 from v1.14 backfill)
  last 6 weeks: 432 (was 0 before this seed)
  swimmer_pbs: 14
  swimmer_suits: 69 buckets, 69 with both suit values
  swimmer_starts: 69 buckets, 69 with multiple start types
"""
import os
import random
import subprocess
from datetime import datetime, timedelta, timezone

# === CONFIG ===
COACH_ID = "9b72e5d7-ffcd-4a77-abe3-e0d2b209df54"
PROJECT_DIR = "/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2"
RNG_SEED = 42  # deterministic

# Existing 8 swimmers (id, first_name, last_name, race PB 50m Free ms)
EXISTING_SWIMMERS = [
    ("e9137805-0c1b-4361-aa2e-a47c150d6767", "Alice", "Freestyler", 26800),
    ("7e6ca6c2-b586-4c6c-8bf7-d363c862782e", "Bob", "Freestyler", 27200),
    ("a7a71d18-0261-41f8-b606-3930be6eb44a", "Charlie", "Freestyler", 27900),
    ("9b2e9233-e128-4714-80c3-daa646b7d5b5", "Diana", "Freestyler", 28400),
    ("b8c13ff4-730e-4403-8ca5-d28a2bbecc09", "Ethan", "Freestyler", 29500),
    ("994b7ebf-41fa-47e2-8a18-715e9d53ce26", "Fiona", "Freestyler", 30100),
    ("1b5261d6-8bbc-4109-8dc5-6c4d3e52e814", "George", "Freestyler", 31200),
    ("bea69b89-0426-4c51-9eef-29b40fa99715", "Hannah", "Freestyler", 32800),
]

# 4 new swimmers with stroke variety
# (first_name, last_name, primary_distance, primary_stroke, race PB ms)
NEW_SWIMMERS = [
    ("Isla", "Backstroker", 50, "Back", 30500),
    ("Jack", "Breaststroker", 50, "Breast", 33000),
    ("Kira", "Fly", 50, "Fly", 29500),
    ("Liam", "IMer", 100, "IM", 65000),
]

# 2 edge cases
EDGE_NO_HISTORY = ("Maya", "NoHistory")          # cold start — has PBs but no recorded_times
EDGE_NO_TRAINING_PB = ("Noah", "NoTrainingPBs")   # has recorded_times but only max PBs

# Intensity multipliers (relative to race PB)
INTENSITY_FACTORS = {
    "max": 1.00,        # race PB
    "threshold": 1.05,  # T4 — comfortably hard
    "moderate": 1.12,  # T2 — aerobic
    "easy": 1.20,       # T1 — easy aerobic
    "tempo": 1.08,      # T3 — between threshold and moderate
}

# 6-week training history (last 6 weeks) — shifted from the v1.15
# Dec 2025 → Apr 2026 window to align with the 6-week analytics
# window the v2.0 analytics views use. The v1.15 dates put all
# data outside the analytics trend window, so the Analytics tab
# showed "Insufficient data" for every swimmer.
#
# (start_date, end_date, phase_factor, sigma_ms) — base → build → taper
NOW = datetime.now(timezone.utc)
SIX_WEEKS_AGO = NOW - timedelta(weeks=6)
TWO_WEEKS_AGO = NOW - timedelta(weeks=2)
ONE_WEEK_AGO = NOW - timedelta(weeks=1)
PHASES = [
    (SIX_WEEKS_AGO, TWO_WEEKS_AGO, 1.03, 250),  # base: 3% slower, ±250ms
    (TWO_WEEKS_AGO, ONE_WEEK_AGO,  1.01, 350),  # build: 1% slower, ±350ms
    (ONE_WEEK_AGO, NOW,            0.97, 100),  # taper: 3% faster, ±100ms (PBs!)
]

# Workout templates (used to generate sessions)
# (title, intensity_label, stroke, distance, reps)
WORKOUT_TEMPLATES = [
    ("Tuesday threshold 50s",     "threshold", "Free",   50,  4),
    ("Wednesday aerobic 100s",    "moderate",  "Free",   100, 4),
    ("Thursday sprint 25s",       "max",       "Free",   25,  8),
    ("Friday IM 100s",            "tempo",     "IM",     100, 4),
    ("Saturday distance 400",     "moderate",  "Free",   400, 1),
    ("Sunday recovery",           "easy",      "Free",   50,  6),
    ("Tuesday backstroke 50s",    "tempo",     "Back",   50,  4),
    ("Wednesday breaststroke 100s","tempo",    "Breast", 100, 4),
    ("Thursday fly 50s",          "threshold", "Fly",    50,  4),
    ("Saturday long aerobic",     "moderate",  "Free",   200, 1),
    ("Tuesday moderate base",     "moderate",  "Free",   50,  6),
    ("Friday Free endurance",     "easy",      "Free",   100, 4),
]

# === HELPERS ===
def gen_uuid():
    """Generate a deterministic UUID from a counter + seed (so reruns produce same IDs)."""
    global _uuid_counter
    _uuid_counter += 1
    return f"{RNG_SEED:08x}-0000-4000-8000-{_uuid_counter:012d}"

_uuid_counter = 0

def gaussian_ms(mu, sigma):
    """Box-Muller for reproducible gaussian noise."""
    return int(random.gauss(mu, sigma))

# === MAIN SEED LOGIC ===
def build_seed_data():
    random.seed(RNG_SEED)
    global _uuid_counter
    _uuid_counter = 0

    swimmers = []           # [(id, first_name, last_name)]
    workout_ids = {}        # title -> id
    workout_set_ids = []    # [(workout_id, set_idx, distance, stroke, intensity_label, reps)]
    session_ids = []        # [(session_id, workout_id, started_at, completed_at, reviewed_at)]
    recorded_times = []     # [(id, session_id, workout_set_id, swimmer_id, time_ms, intensity, gear, ...)]
    pbs_to_insert = []      # [(id, swimmer_id, distance, stroke, time_ms, gear, intensity, recorded_at)]

    # --- 1. SWIMMERS ---
    # Existing 8 (use their existing IDs)
    for sid, first, last, _ in EXISTING_SWIMMERS:
        swimmers.append((sid, first, last))
    # 4 new (backstroke, breast, fly, IM)
    for first, last, _dist, _stroke, _pb in NEW_SWIMMERS:
        swimmers.append((gen_uuid(), first, last))
    # 2 edge cases
    swimmers.append((gen_uuid(), EDGE_NO_HISTORY[0], EDGE_NO_HISTORY[1]))
    swimmers.append((gen_uuid(), EDGE_NO_TRAINING_PB[0], EDGE_NO_TRAINING_PB[1]))

    # --- 2. WORKOUTS ---
    for title, intensity, stroke, distance, reps in WORKOUT_TEMPLATES:
        wid = gen_uuid()
        workout_ids[title] = wid
        # One workout_set per workout (simple structure for the seeder)
        wsid = gen_uuid()
        workout_set_ids.append((wsid, wid, 0, distance, stroke, intensity, reps))

    # --- 3. SESSIONS (one per workout per week, rotating) ---
    # 6 weeks × 2 sessions/week = 12 sessions (vs v1.15's 32).
    # Each session uses a workout from WORKOUT_TEMPLATES (rotating).
    workout_titles = [t[0] for t in WORKOUT_TEMPLATES]
    n_templates = len(workout_titles)

    sessions_meta = []  # for debugging
    for week in range(6):
        for day_idx, day in enumerate(["Tuesday", "Thursday"]):
            # Pick a workout (rotate)
            template_idx = (week * 2 + day_idx) % n_templates
            title = workout_titles[template_idx]
            workout_id = workout_ids[title]
            wid, wid_uuid = "wid", workout_id

            # Date: start at the 6-weeks-ago mark + week*7 days
            # v1.15 had hardcoded Dec 15 2025; v2.0 anchors to NOW
            # so the data lands in the analytics trend window.
            base_date = SIX_WEEKS_AGO + timedelta(weeks=week, days=day_idx * 2)
            started_at = base_date.replace(hour=8, minute=0)
            completed_at = started_at + timedelta(hours=1)
            reviewed_at = started_at + timedelta(hours=2)

            session_id = gen_uuid()
            session_ids.append((session_id, workout_id, started_at, completed_at, reviewed_at))
            sessions_meta.append((session_id, week, day, title))

    # --- 4. RECORDED TIMES ---
    # For each (session, swimmer, set): generate time_ms = base_PB × intensity × phase × noise
    # Base PB lookup (per swimmer)
    swimmer_pbs = {}
    # Existing 8: race PB 50m Free
    for sid, first, last, pb_ms in EXISTING_SWIMMERS:
        swimmer_pbs[sid] = {"Free": {50: pb_ms, 100: int(pb_ms * 1.95), 200: int(pb_ms * 4.1), 400: int(pb_ms * 8.3)},
                             "Back": {50: int(pb_ms * 1.10)},
                             "Breast": {50: int(pb_ms * 1.20)},
                             "Fly": {50: int(pb_ms * 1.05)},
                             "IM": {100: int(pb_ms * 4.0)}}
    # New 4: their primary stroke is the focus, but they also swim Free
    for first, last, dist, stroke, pb_ms in NEW_SWIMMERS:
        # Find the new swimmer's id (the next 4 after the existing 8)
        idx = NEW_SWIMMERS.index((first, last, dist, stroke, pb_ms))
        sid = swimmers[8 + idx][0]
        swimmer_pbs[sid] = {"Free": {50: int(pb_ms * 0.95), 100: int(pb_ms * 1.95)},
                            stroke: {dist: pb_ms, 100: int(pb_ms * 2.0)}}

    # Edge cases
    no_history_id = swimmers[12][0]
    no_training_id = swimmers[13][0]
    swimmer_pbs[no_history_id] = {"Free": {50: 31500}}  # has a PB but no history
    swimmer_pbs[no_training_id] = {"Free": {50: 29000}}  # has history (below) but only max PB

    # Iterate sessions
    for session_id, workout_id, started_at, completed_at, reviewed_at in session_ids:
        # Get the workout's set
        workout_set = next(ws for ws in workout_set_ids if ws[1] == workout_id)
        wsid, _, order_idx, distance, stroke, intensity, reps = workout_set

        # Phase factor + sigma
        phase_factor, sigma = 1.02, 250
        for p_start, p_end, p_factor, p_sigma in PHASES:
            if p_start <= started_at < p_end:
                phase_factor, sigma = p_factor, p_sigma
                break

        intensity_factor = INTENSITY_FACTORS[intensity]

        # Edge cases
        regular_swimmers = [s[0] for s in swimmers[:12]]
        # no-history swimmer gets NO recorded_times
        swimmers_in_session = regular_swimmers + [no_training_id]

        for swimmer_id in swimmers_in_session:
            # Get base PB for this swimmer + stroke + distance
            base_pb = swimmer_pbs.get(swimmer_id, {}).get(stroke, {}).get(distance)
            if base_pb is None:
                # Swimmer doesn't have a PB for this stroke/distance — skip
                # (the predictor will fall back to a different bucket)
                continue

            # For each rep
            for rep in range(reps):
                time_ms = max(0, int(base_pb * intensity_factor * phase_factor + gaussian_ms(0, sigma)))
                recorded_at = started_at + timedelta(seconds=rep * 30)

                # Build a row that matches the recorded_times schema
                # source must be 'auto', 'manual', or 'unassigned' (check constraint)
                rt_id = gen_uuid()
                row = (rt_id, session_id, workout_id, wsid, swimmer_id,
                       rep, time_ms, "auto",  # source
                       0.95,  # assignment_confidence
                       recorded_at,  # created_at
                       intensity, "none", stroke, distance,
                       rep,  # lap_order
                       swimmer_id,  # paired_swimmer_id (auto-paired)
                       95,  # confidence
                       0)  # wave_number
                recorded_times.append(row)

    # --- 5. PBs (seeded directly for the full 24-per-swimmer matrix) ---
    # For each (swimmer, stroke, distance): derive race PB from min recorded_time
    # (or use the base race PB for swimmers with no data at that combo).
    # Then derive threshold/moderate/easy PBs via multipliers.
    # This gives 24 PBs per regular swimmer (6 combos × 4 intensities).
    pb_min = {}  # (swimmer, stroke, distance) -> min time_ms (race PB)
    for rt in recorded_times:
        (_, _, _, _, swimmer_id, _, time_ms, _, _,
         _, _, _, stroke, distance, _, _, _, _) = rt
        key = (swimmer_id, stroke, distance)
        if key not in pb_min or time_ms < pb_min[key]:
            pb_min[key] = time_ms

        # 6 (stroke, distance) combos per swimmer
    pb_combos = [
        ("Free", 50), ("Free", 100), ("Free", 200),
        ("IM", 100),
        ("Back", 50), ("Breast", 50),
    ]
    # v2.0: the swimmer_pbs UNIQUE constraint is (swimmer_id, stroke,
    # distance, gear) — no intensity column. So we can only insert
    # ONE PB per (swimmer, stroke, distance, gear) key. The v1.15
    # seeder tried to insert 4 intensity variants per combo and
    # blew up on the unique constraint. v2.0 inserts just the
    # race PB (intensity='max') per combo. The intensity variants
    # can be added back when the schema is upgraded to include
    # intensity in the UNIQUE key (separate migration).
    intensity_multipliers = {"max": 1.00}

    for swimmer_id, first, last, *_ in swimmers[:12]:  # regular swimmers only
        for stroke, distance in pb_combos:
            # Race PB: min from recorded_times, or estimate from the
            # swimmer's primary distance PB × stroke-specific multiplier
            race_pb = pb_min.get((swimmer_id, stroke, distance))
            if race_pb is None:
                # Estimate: scale from the swimmer's known PB
                base_50free = swimmer_pbs.get(swimmer_id, {}).get("Free", {}).get(50, 30000)
                stroke_factor = {"Free": 1.0, "Back": 1.10, "Breast": 1.20, "Fly": 1.05, "IM": 4.0}.get(stroke, 1.0)
                dist_factor = distance / 50.0 if stroke in ("Free", "Back", "Breast", "Fly") else 4.0
                race_pb = int(base_50free * stroke_factor * dist_factor)

            for intensity, mult in intensity_multipliers.items():
                pb_time = int(race_pb * mult)
                # v2.0: use NOW (end of taper) for the PB recorded_at
                recorded_at = NOW
                pbs_to_insert.append((gen_uuid(), swimmer_id, distance, stroke, pb_time,
                                     "none", intensity, recorded_at))

    # Edge cases
    # 1. No-history swimmer: ONE PB at max only (cold start)
    pbs_to_insert.append((gen_uuid(), no_history_id, 50, "Free", 31500, "none", "max",
                          NOW))
    # 2. No-training-PBs swimmer: has recorded_times but only max PBs
    #    (Tier 3 fallback test case). Add max PBs for the 6 combos, no training variants.
    for stroke, distance in pb_combos:
        race_pb = pb_min.get((no_training_id, stroke, distance))
        if race_pb is None:
            race_pb = 29000 if stroke == "Free" and distance == 50 else int(29000 * (distance / 50.0) * 1.1)
        pbs_to_insert.append((gen_uuid(), no_training_id, distance, stroke, race_pb,
                             "none", "max", NOW))

    return {
        "swimmers": swimmers,
        "workout_ids": workout_ids,
        "workout_set_ids": workout_set_ids,
        "session_ids": session_ids,
        "sessions_meta": sessions_meta,
        "recorded_times": recorded_times,
        "pbs": pbs_to_insert,
        "no_history_id": no_history_id,
        "no_training_id": no_training_id,
    }


def build_sql(data):
    """Build a single SQL file with all INSERTs (idempotent via DELETE first)."""
    lines = []

    # PHASE 2.6 v1.15.0: the update_swimmer_pbs() trigger has a stale
    # ON CONFLICT (no intensity column). The seeder inserts recorded_times
    # directly, which fires the trigger, which then errors out. Set
    # session_replication_role = 'replica' to skip user triggers
    # during the seed. Re-enable at the end.
    lines.append("-- === DISABLE TRIGGERS (replica mode skips user triggers) ===")
    lines.append("SET session_replication_role = replica;")
    lines.append("")

    # DELETE existing data for the 8 existing swimmers (re-seed)
    existing_sids = [s[0] for s in EXISTING_SWIMMERS]
    lines.append("-- === CLEANUP: re-seed the 8 existing swimmers ===")
    lines.append(f"DELETE FROM swimmer_pbs WHERE swimmer_id IN ({','.join(repr(s) for s in existing_sids)});")
    lines.append(f"DELETE FROM recorded_times WHERE swimmer_id IN ({','.join(repr(s) for s in existing_sids)}) "
                 f"AND created_at < NOW() - INTERVAL '7 days';")  # keep recent test sessions
    lines.append("")

    # --- 1. SWIMMERS (4 new + 2 edge cases) ---
    lines.append("-- === NEW SWIMMERS ===")
    for sid, first, last in data["swimmers"][8:]:  # skip existing 8
        full_name = f"{first} {last}"
        # Escape single quotes in name
        full_name_escaped = full_name.replace("'", "''")
        first_escaped = first.replace("'", "''")
        last_escaped = last.replace("'", "''")
        lines.append(f"INSERT INTO swimmers (id, first_name, last_name, name, coach_id, created_at, main_stroke) "
                     f"VALUES ('{sid}', '{first_escaped}', '{last_escaped}', '{full_name_escaped}', '{COACH_ID}', NOW(), 'Free') "
                     f"ON CONFLICT (id) DO NOTHING;")
    lines.append("")

    # --- 2. WORKOUTS + WORKOUT SETS ---
    for title, wid in data["workout_ids"].items():
        # status must be 'draft', 'scheduled', 'in_progress', or 'complete' (check constraint)
        # v2.0: schedule the first workout for the upcoming Tuesday so
        # the Today tab doesn't show "No workout scheduled."
        # session_ids tuples are (session_id, workout_id, started_at, completed_at, reviewed_at)
        first_started_at = data["session_ids"][0][2] if data["session_ids"] else None
        scheduled_date = first_started_at.date().isoformat() if first_started_at else NOW.date().isoformat()
        lines.append(f"INSERT INTO workouts (id, coach_id, title, status, scheduled_at, am_pm, "
                     f"workout_text, created_at, updated_at) "
                     f"VALUES ('{wid}', '{COACH_ID}', '{title}', 'complete', "
                     f"'{scheduled_date}', 'AM', '50m Free T4 x 4', NOW(), NOW()) "
                     f"ON CONFLICT (id) DO NOTHING;")
    for wsid, wid, order, dist, stroke, intensity, reps in data["workout_set_ids"]:
        lines.append(f"INSERT INTO workout_sets (id, workout_id, order_index, reps, distance, stroke, "
                     f"intensity_type, intensity_label, gear, created_at, pace_target_distance) "
                     f"VALUES ('{wsid}', '{wid}', {order}, {reps}, {dist}, '{stroke}', "
                     f"'RPE', '{intensity}', 'none', NOW(), {dist}) "
                     f"ON CONFLICT (id) DO NOTHING;")
    lines.append("")

    # --- 3. SESSIONS ---
    lines.append("-- === HISTORICAL SESSIONS ===")
    for sid, wid, started, completed, reviewed in data["session_ids"]:
        lines.append(f"INSERT INTO sessions (id, workout_id, coach_id, started_at, completed_at, reviewed_at) "
                     f"VALUES ('{sid}', '{wid}', '{COACH_ID}', '{started.isoformat()}', "
                     f"'{completed.isoformat()}', '{reviewed.isoformat()}') "
                     f"ON CONFLICT (id) DO NOTHING;")
    lines.append("")

    # --- 4. RECORDED TIMES (batched, ~500 per batch) ---
    lines.append("-- === RECORDED TIMES ===")
    batch_size = 500
    rts = data["recorded_times"]
    for i in range(0, len(rts), batch_size):
        batch = rts[i:i+batch_size]
        values = []
        for rt in batch:
            (rt_id, session_id, workout_id, wsid, swimmer_id, rep, time_ms, source,
             conf, created_at, intensity, gear, stroke, distance, lap_order,
             paired_swimmer_id, confidence, wave_number) = rt
            values.append(
                f"('{rt_id}', '{session_id}', '{workout_id}', '{wsid}', '{swimmer_id}', "
                f"{time_ms}, {intensity}, '{gear}', {wave_number}, '{created_at.isoformat()}', "
                f"'{source}', {confidence}, {rep}, {distance}, '{stroke}', "
                f"{conf}, {lap_order}, '{paired_swimmer_id}')"
            )
        lines.append(f"INSERT INTO recorded_times (id, session_id, workout_id, workout_set_id, swimmer_id, "
                     f"time_ms, intensity, gear, wave_number, created_at, "
                     f"source, confidence, rep_index, distance, stroke, "
                     f"assignment_confidence, lap_order, paired_swimmer_id) VALUES\n  "
                     + ",\n  ".join(values) + "\nON CONFLICT (id) DO NOTHING;")
    lines.append("")

    # --- 5. PBs ---
    lines.append("-- === PERSONAL BESTS ===")
    for pb in data["pbs"]:
        (pb_id, swimmer_id, distance, stroke, time_ms, gear, intensity, recorded_at) = pb
        lines.append(f"INSERT INTO swimmer_pbs (id, swimmer_id, distance, stroke, time_ms, gear, intensity, recorded_at) "
                     f"VALUES ('{pb_id}', '{swimmer_id}', {distance}, '{stroke}', {time_ms}, "
                     f"'{gear}', '{intensity}', '{recorded_at.isoformat()}') "
                     f"ON CONFLICT (swimmer_id, stroke, distance, gear) DO NOTHING;")
    lines.append("")

    # Re-enable triggers
    lines.append("-- === RE-ENABLE TRIGGERS ===")
    lines.append("SET session_replication_role = origin;")
    lines.append("")

    return "\n".join(lines)


def main():
    print("Building seed data...")
    data = build_seed_data()
    print(f"  Swimmers: {len(data['swimmers'])} (8 existing + 6 new)")
    print(f"  Workouts: {len(data['workout_ids'])}")
    print(f"  Sessions: {len(data['session_ids'])}")
    print(f"  Recorded times: {len(data['recorded_times'])}")
    print(f"  PBs: {len(data['pbs'])}")

    print("\nBuilding SQL...")
    sql = build_sql(data)
    sql_path = "/tmp/seed_v20.sql"
    with open(sql_path, "w") as f:
        f.write(sql)
    print(f"  Wrote {sql_path} ({len(sql)} bytes)")

    print("\nRunning SQL via supabase CLI...")
    with open(os.path.expanduser('~/.supabase/token')) as f:
        token = f.read().strip()
    env = os.environ.copy()
    env['SUPABASE_ACCESS_TOKEN'] = token

    result = subprocess.run(
        ['supabase', 'db', 'query', '--linked', '-f', sql_path],
        capture_output=True, text=True, env=env, timeout=120
    )
    print(f"  exit: {result.returncode}")
    if result.stdout:
        print(f"  stdout: {result.stdout[:300]}")
    if result.stderr and 'Initialising' not in result.stderr:
        print(f"  stderr: {result.stderr[:500]}")

    if result.returncode == 0:
        print("\nVerification...")
        # Quick per-stroke sanity check
        verify_path = "/tmp/seed_verify.sql"
        with open(verify_path, "w") as f:
            f.write("SELECT stroke, count(*) FROM swimmer_pbs GROUP BY stroke ORDER BY stroke;")
        verify = subprocess.run(
            ['supabase', 'db', 'query', '--linked', '-f', verify_path],
            capture_output=True, text=True, env=env, timeout=30
        )
        print(verify.stdout)


if __name__ == "__main__":
    main()
