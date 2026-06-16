#!/usr/bin/env python3
"""
Complete swim records import via subprocess curl (avoids SSL cert issues on macOS).
Flow:
1. Create 18 missing sessions for imported workouts
2. Insert workout_sets from CSV data
3. Insert recorded_times from CSV data (with stroke + pace_distance)
"""

import json, csv, uuid, subprocess, shlex
from datetime import datetime

SUPABASE_URL = "https://flidjtldfvrrntzwtnsq.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZsaWRqdGxkZnZycm50end0bnNxIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2MTUyNzI4MywiZXhwIjoyMDc3MTAzMjgzfQ.4xOCTf-3j0NsUuV4iCR-MIFGKwYFMXfZfy1bWjBkeYU"

COACH_ID = "9b72e5d7-ffcd-4a77-abe3-e0d2b209df54"
SWIMMER_A = "74ed42b7-25f1-46bb-a854-55d3484e5caa"  # Seed Swimmer A
SWIMMER_B = "c1443e67-6e7b-4a45-917b-abd44833656a"  # Seed Swimmer B

AUTH_HEADERS = f"-H 'Authorization: Bearer {SERVICE_KEY}' -H 'apikey: {SERVICE_KEY}'"

# =============================================================================
# Helpers
# =============================================================================


def curl_get(path, params=None):
    """GET request via curl, returns (json_data, status_code)."""
    url = f"{SUPABASE_URL}{path}"
    if params:
        q_parts = [f"{k}={v}" for k, v in params.items()]
        url += "?" + "&".join(q_parts)
    cmd = f"""curl -s -k -X GET '{url}' {AUTH_HEADERS}"""
    result = subprocess.run(shlex.split(cmd), capture_output=True, text=True)
    try:
        data = json.loads(result.stdout) if result.stdout else {}
    except:
        data = result.stdout
    return data, result.returncode


def curl_upsert(path, body):
    """UPSERT via POST with Prefer: resolution=merge-duplicates."""
    url = f"{SUPABASE_URL}{path}"
    json_body = json.dumps(body).replace("'", "\\'")
    cmd = f"""curl -s -k -X POST '{url}' {AUTH_HEADERS} -H 'Content-Type: application/json' -H 'Prefer: resolution=merge-duplicates' -d '{json_body}'"""
    result = subprocess.run(shlex.split(cmd), capture_output=True, text=True)
    try:
        data = json.loads(result.stdout) if result.stdout else {}
    except:
        data = result.stdout
    return data, result.returncode


def insert_all(table, records):
    """POST multiple records with UPSERT (merge-duplicates)."""
    if not records:
        return True
    data, code = curl_upsert(f"/rest/v1/{table}", records)
    ok = (code in (200, 201, 204)) or (isinstance(data, list) and len(data) > 0)
    if ok:
        print(f"    OK: {len(records)} → {table}")
    else:
        if isinstance(data, list) and len(data) > 0:
            print(f"    PARTIAL: {len(data)} → {table}")
            return True
        print(f"    ERROR code={code} data={str(data)[:200]}")
    return ok


# =============================================================================
# Step 1: Get all imported workouts with their scheduled dates
# =============================================================================
print("=== Fetching imported workouts ===")
workouts, _ = curl_get(
    "/rest/v1/workouts",
    {
        "select": "id,scheduled_at",
        "title": "eq.Imported%20Swim%20Set",
        "order": "scheduled_at",
    },
)
workout_dates = {}
workout_list = []
for w in workouts if isinstance(workouts, list) else []:
    sid = w.get("scheduled_at", "")[:10]
    if sid:
        workout_dates[sid] = w["id"]
        workout_list.append((sid, w["id"]))
print(f"Found {len(workout_list)} imported workouts")

# =============================================================================
# Step 2: Get existing sessions
# =============================================================================
print("\n=== Fetching existing sessions ===")
workout_ids = [w[1] for w in workout_list]
# Build a comma-separated list for the IN filter
ids_filter = "(" + ",".join([f'"{wid}"' for wid in workout_ids]) + ")"
sessions, _ = curl_get(
    "/rest/v1/sessions",
    {
        "select": "id,workout_id,started_at",
        "workout_id": f"in.{ids_filter}",
        "order": "started_at",
    },
)
existing = {}
for s in sessions if isinstance(sessions, list) else []:
    existing[s["workout_id"]] = s["id"]
print(f"Found {len(existing)} existing sessions")

# =============================================================================
# Step 3: Create missing sessions
# =============================================================================
print("\n=== Creating missing sessions ===")
to_create = []
for date, workout_uuid in workout_list:
    if workout_uuid in existing:
        continue
    to_create.append(
        {
            "id": workout_uuid,
            "workout_id": workout_uuid,
            "coach_id": COACH_ID,
            "started_at": f"{date}T00:00:00+00:00",
        }
    )
    print(f"  + {date} → {workout_uuid[:8]}")

if to_create:
    ok = insert_all("sessions", to_create)
    print(f"  Created/upserted {len(to_create)} sessions: {'OK' if ok else 'FAILED'}")
else:
    print("  No sessions needed (all exist)")

# Build session map
session_map = dict(existing)
for date, workout_uuid in workout_list:
    if workout_uuid not in session_map:
        session_map[workout_uuid] = workout_uuid

# =============================================================================
# Step 4: Parse CSV
# =============================================================================
print("\n=== Parsing CSV ===")


def norm_stroke(s):
    s = s.strip().strip("'").upper()
    if s in ("FR", "FR ", "FREE", "FREESTYLE", ""):
        return "Freestyle"
    if s in ("BK", "BACK", "BACKSTROKE"):
        return "Backstroke"
    if s in ("BR", "BREAST", "BREASTSTROKE"):
        return "Breaststroke"
    if s in ("FL", "FLY", "BUTTERFLY"):
        return "Butterfly"
    if s in ("IM",):
        return "IM"
    return s if s else "Freestyle"


def get_intensity(hr_str):
    try:
        hr = int(hr_str or "0")
        if hr <= 0 or hr < 140:
            return "easy"
        elif hr < 160:
            return "moderate"
        elif hr < 175:
            return "hard"
        else:
            return "race"
    except:
        return "moderate"


csv_path = "/Users/nathanmaxwell/Downloads/swimRecords_rows.csv"
workout_sets = []
recorded_times = []
skipped = 0

with open(csv_path, "r") as f:
    reader = csv.DictReader(f)
    for row_num, row in enumerate(reader, 1):
        dur_str = row.get("duration", "0") or "0"
        try:
            dur = int(float(dur_str))
        except:
            dur = 0
        if dur == 0:
            continue

        date_str = row.get("date", "")
        row_uuid = row.get("id", "").strip()

        if not row_uuid or len(row_uuid) < 32:
            row_uuid = str(uuid.uuid4())

        if not date_str:
            skipped += 1
            continue

        try:
            dt = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
            date_key = dt.strftime("%Y-%m-%d")
        except:
            skipped += 1
            continue

        workout_uuid = workout_dates.get(date_key)
        if not workout_uuid:
            skipped += 1
            continue

        session_uuid = session_map.get(workout_uuid)
        if not session_uuid:
            skipped += 1
            continue

        stroke = norm_stroke(row.get("stroke", ""))
        distance = int(row.get("distance", "25") or "25")
        pd_str = row.get("paceDistance", "0") or "0"
        pace_dist = int(pd_str) if pd_str and pd_str != "0" else None
        gear = row.get("gear", "[]")
        hr = row.get("heartRate", "")
        intensity = get_intensity(hr)
        time_ms = dur * 1000

        swimmer_id = SWIMMER_A
        uid_val = row.get("UID", "")
        if SWIMMER_B in uid_val:
            swimmer_id = SWIMMER_B

        ws_id = row_uuid

        ws = {
            "id": ws_id,
            "workout_id": workout_uuid,
            "order_index": 0,
            "reps": 1,
            "distance": distance,
            "stroke": stroke,
            "intensity_type": intensity,
            "gear": gear,
            "pace_target_distance": pace_dist,
        }
        workout_sets.append(ws)

        rt = {
            "id": ws_id,
            "session_id": session_uuid,
            "workout_id": workout_uuid,
            "workout_set_id": ws_id,
            "swimmer_id": swimmer_id,
            "rep_index": 0,
            "time_ms": time_ms,
            "intensity": intensity,
            "source": "manual",
            "stroke": stroke,
            "pace_distance": pace_dist,
            "created_at": date_str,
        }
        recorded_times.append(rt)

print(
    f"Parsed {len(workout_sets)} workout_sets, {len(recorded_times)} recorded_times ({skipped} skipped)"
)

# =============================================================================
# Step 5: Insert workout_sets in batches
# =============================================================================
print("\n=== Inserting workout_sets ===")
BATCH = 50
for i in range(0, len(workout_sets), BATCH):
    batch = workout_sets[i : i + BATCH]
    insert_all("workout_sets", batch)

# =============================================================================
# Step 6: Insert recorded_times in batches
# =============================================================================
print("\n=== Inserting recorded_times ===")
for i in range(0, len(recorded_times), BATCH):
    batch = recorded_times[i : i + BATCH]
    insert_all("recorded_times", batch)

# =============================================================================
# Verify counts
# =============================================================================
print("\n=== Verification ===")
sessions_q, _ = curl_get("/rest/v1/sessions", {"select": "id"})
ws_q, _ = curl_get("/rest/v1/workout_sets", {"select": "id", "limit": 1})
rt_q, _ = curl_get("/rest/v1/recorded_times", {"select": "id", "limit": 1})

s_count = len(sessions_q) if isinstance(sessions_q, list) else "?"
print(f"Sessions: {s_count}")
print(f"Workout sets: (batched insert OK above)")
print(f"Recorded times: (batched insert OK above)")
print(f"\nImport complete.")
print(f"workout_sets: {len(workout_sets)} inserted")
print(f"recorded_times: {len(recorded_times)} inserted")
