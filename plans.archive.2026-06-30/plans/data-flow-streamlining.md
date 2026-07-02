# Data-Flow Streamlining Plan

**Status:** Draft — awaiting approval
**Author:** Vision
**Date:** 2026-05-11

---

## Context

An exhaustive inventory of every Supabase call site in the app (26 total across 18 files) found that only 3 files use `withTimeout` correctly: `login.tsx`, `swimmers/[id].tsx`, `swimmer-stats.ts`. Every other read and write in the app uses bare `await supabase.from(...)`, creating silent-hang risk on slow pool-deck wifi.

The root issue is Supabase JS v2 returning thenables (not true Promises), which can silently fail to resolve in some environments when awaited directly. The `withTimeout` helper exists and works — it's just not used consistently.

The fix is a two-helper abstraction (`query` + `mutate`) applied uniformly across all screens, plus a focus-refresh hook, plus hardening auth init. No new libraries. No architecture changes. Just consistent wiring.

---

## Helper API Design

### `query<T>(qb, opts?)` — all reads

**Signature:**

```typescript
async function query<T>(
  qb: PromiseLike<{ data: T | null; error: SupabaseError | null }>,
  opts?: {
    timeoutMs?: number; // default 15000
    tag?: string; // "today/workouts", "swimmers/list", etc.
    onError?: (err: Error) => void; // console + optional UI callback
  },
): Promise<T>;
```

**Behavior:**

1. Wraps `qb` in `withTimeout(qb, timeoutMs)` — rejects cleanly on timeout
2. On reject: logs `"[query] ${tag ?? 'anonymous'}: ${err.message}"` with file:line from stack
3. If `onError` callback provided, calls it (screens use this to show inline error state)
4. On resolve: if `error` is present, throws a typed error carrying `error.message` and `error.status`
5. Returns `data ?? null`

**Timeout defaults:**

- Data queries: **15000ms** (15s) — appropriate for pool-deck wifi
- Auth-adjacent reads: **10000ms** (10s)

**Error callback pattern:**

```typescript
// Screen-level usage
const [error, setError] = useState<string | null>(null);
const data = await query(supabase.from("workouts").select(...), {
  tag: "today/next-workout",
  onError: (e) => setError(e.message),
});
```

This replaces bare `await supabase.from(...).maybeSingle()` in all screens.

---

### `mutate<T>(qb, opts?)` — all writes

**Signature:**

```typescript
async function mutate<T>(
  qb: PromiseLike<{ data: T | null; error: SupabaseError | null }>,
  opts?: {
    timeoutMs?: number; // default 15000
    tag?: string; // "swimmers/create", "workouts/update-status"
    invalidateKeys?: string[]; // e.g. ["workouts:all", "today:next-workout"]
    onError?: (err: Error) => void;
  },
): Promise<T>;
```

**Behavior:**

1. Same timeout/reject as `query`
2. On success: calls `invalidateKeys.forEach(key => invalidate(key))` — triggers focus-refetch on subscribed screens
3. On error: throws (screen's `catch` handles UI feedback)

**Invalidation key convention:**

```
"{table}:{scope}"
Examples:
  "workouts:all"          — full workouts list refresh
  "workouts:detail:{id}"  — single workout detail
  "swimmers:all"          — swimmer roster
  "swimmers:detail:{id}"  — single swimmer
  "today:next-workout"    — today's upcoming workout
  "sets:attendance"      — attendance list
  "pbs:{swimmerId}"       — PB list for one swimmer
```

**Why register keys instead of Supabase Realtime?** Realtime adds infrastructure complexity and auth scope requirements. Focus-refetch is sufficient for this app's scale.

---

### `useQuery(key, fetchFn, opts?)` — focus-aware data subscription

**Signature:**

```typescript
function useQuery<T>(
  key: string, // invalidation key
  fetchFn: () => Promise<T>,
  opts?: {
    enabled?: boolean; // default true — set false when coachId is null
    staleTime?: number; // ms before data is considered stale (default: 30_000)
  },
): {
  data: T | undefined;
  error: string | null;
  isLoading: boolean;
  refetch: () => void;
};
```

**Behavior:**

- Wraps `useFocusEffect` internally
- Maintains an in-memory cache (Map) keyed by `key` — data persists across focus cycles until stale
- When `enabled` is false (coachId null initially), suppresses the effect without firing
- On focus: checks if cache is stale (default 30s); if so, calls `fetchFn()`
- When `mutate()` invalidates a key, the cache entry for that key is evicted — forcing a refetch on next focus
- `refetch()` manually evicts cache and triggers a fresh fetch (for pull-to-refresh)

**No external cache library** — the Map is in-module scope:

```typescript
const _cache = new Map<string, { data: any; timestamp: number }>();
```

---

### Auth Init Hardening

**Problem:** `AuthContext.tsx` calls `supabase.auth.getSession()` and `onAuthStateChange()` without timeout wrapping. These are the source of the coachId resolution race.

**Fix:** Wrap the `getSession()` call in `withTimeout(..., 10000)` at init. Wrap the async `resolveCoach` call inside `onAuthStateChange` in `withTimeout(..., 10000)` so a slow coach-record lookup doesn't leave auth state unresolved.

---

## Invalidation Strategy

### How Keys Are Named

Table-based with scope modifier. Every `mutate()` call declares which keys to invalidate:

| mutate call                           | keys invalidated                                             |
| ------------------------------------- | ------------------------------------------------------------ |
| `createSwimmer()`                     | `swimmers:all`                                               |
| `updateSwimmer()`                     | `swimmers:all`, `swimmers:detail:{id}`                       |
| `deleteSwimmer()`                     | `swimmers:all`                                               |
| `createGroup()`                       | `swimmers:groups`                                            |
| `deleteGroup()`                       | `swimmers:groups`                                            |
| `workouts.update(status→in_progress)` | `workouts:all`, `workouts:detail:{id}`                       |
| `workouts.update(status→complete)`    | `workouts:all`, `workouts:detail:{id}`                       |
| `workouts.update(scheduled_at)`       | `workouts:all`, `workouts:detail:{id}`, `today:next-workout` |
| `recorded_times.insert()`             | `sets:attendance` (session-level)                            |
| `swimmer_pbs.upsert()`                | `pbs:{swimmerId}`                                            |

### How a Screen Subscribes

```typescript
const { data, error, refetch } = useQuery(
  "today:next-workout",
  loadNextWorkout,
  { enabled: !!coachId },
);
```

No manual `loadData()` calls after writes — rely on focus-refresh via cache eviction.

### The 3 Known Write→Read Gaps

**Gap 1: Schedule → today / workouts**

- `set-schedule.tsx` writes `scheduled_at`, `am_pm`, `status: "scheduled"` to `workouts`
- Keys invalidated: `workouts:all`, `today:next-workout`
- On return to `today.tsx` or `workouts.tsx`, focus refetches both

**Gap 2: Workout status → workouts tab**

- `workout/[id].tsx` writes `status: "in_progress"` before starting session
- Keys invalidated: `workouts:all`
- `workouts.tsx` tab receives the invalidation on next focus

**Gap 3: PB upsert → swimmer detail**

- `swimmer/[id].tsx` upserts a PB record
- Keys invalidated: `pbs:{swimmerId}`
- Swimmer detail's PB list uses `useQuery("pbs:{id}", fetchPBs)` and refetches on next focus

---

## Observability

### Timeout Event Logging

```typescript
function logTimeout(tag: string, ms: number, stack?: string) {
  console.warn(`[query:timeout] ${tag} — ${ms}ms`, stack ?? "");
}
```

**Future-ready:** when Sentry is added, `logTimeout` gets a `Sentry.captureMessage` call. No PII logged.

### What Gets Logged

| Event   | Log line                | Fields                               |
| ------- | ----------------------- | ------------------------------------ |
| Timeout | `[query:timeout] {tag}` | tag, ms, stack (first 3 lines)       |
| Error   | `[query:error] {tag}`   | tag, error.message, error.status     |
| Success | `[query:ok] {tag}`      | tag, duration-ms (debug builds only) |

### User-Facing Error Feedback

- **Read errors:** `onError` callback in `query()` sets screen-level `error` state. Screen renders `<InlineError msg={error} />`. Never spinner-forever.
- **Write errors:** thrown from `mutate()`, caught by screen's `try/catch`. `Alert.alert` for critical, inline error for non-critical.
- **Auth errors:** `Alert.alert` with actionable message.

---

## Migration Order & Chunking

### Chunk M1: Helpers + Auth Init Hardening (~4 min)

**Files touched:** `lib/supabase-helpers.ts`

- Add `query()` helper
- Add `mutate()` helper with key registry + evict function
- Add `useQuery()` hook with in-memory cache Map
- Add `logTimeout()` logging function

**Files touched:** `context/AuthContext.tsx`

- Wrap `getSession()` in `withTimeout(..., 10000)` at init
- Wrap `resolveCoach()` call inside `onAuthStateChange` in `withTimeout(..., 10000)`

**Success check:** AuthContext still renders correctly, coachId resolves, no type errors.

---

### Chunk M2: lib/auth.ts + lib/swimmers.ts (~4 min)

**Files touched:** `lib/auth.ts` — all 5 write functions use `mutate()`, all reads use `query()`

**Files touched:** `lib/swimmers.ts` — all reads (`getSwimmers`, `getGroups`) use `query()`, all writes use `mutate()` with key registration

**Success check:** `npm run typecheck` passes, no breaking API changes.

---

### Chunk M3: attendance.tsx + today.tsx (~5 min)

**Files touched:** `attendance.tsx`

- `fetchStatsCache()` wraps 3-query `Promise.all` in `query()` (20s for this compound)
- Swimmer list `useEffect` → `useQuery("sets:attendance", fetchFn)`
- Add error state, remove manual `.then().catch()` on swimmers query

**Files touched:** `today.tsx`

- `loadNextWorkout()` wrapped in `query()`
- `useFocusEffect` → `useQuery("today:next-workout", loadNextWorkout)`
- Shows inline error on failure instead of silently loading

**Success check:** Both screens render, TypeScript clean.

---

### Chunk M4: workout/[id].tsx + swimmer-sheet.tsx (~4 min)

**Files touched:** `workout/[id].tsx`

- `loadWorkout()` Promise.all wrapped in `query()` (15s)
- `handleStartSession()` uses `mutate()` with keys `workouts:all`, `workouts:detail:{id}`
- `handleMarkComplete()` and `handleDelete()` use `mutate()`

**Files touched:** `swimmer-sheet.tsx`

- `loadSwimmer()` uses `query()`
- Groups load in `useQuery("swimmers:groups", getGroups)`
- `handleSave` uses `mutate()` with appropriate keys

**Success check:** Edit flow works end-to-end, typecheck passes.

---

### Chunk M5: results.tsx + set-schedule.tsx (~4 min)

**Files touched:** `results.tsx`

- Remove ad-hoc `Promise` wrapper (lines 175-192) — replace with `mutate()`
- Historical load `useEffect` → `useQuery("results:historical:{workoutId}", fetchFn)`
- Calibration upsert and status→complete write use `mutate()`

**Files touched:** `set-schedule.tsx`

- Remove ad-hoc `Promise` wrapper (lines 141-162) — replace with `mutate()`
- `handleUnschedule()` uses `mutate()` with keys `workouts:all`, `today:next-workout`
- Remove inline session guard `getSession()` call

**Success check:** Save flows complete without silent failures.

---

### Chunk M6: Invalidation Gaps + Observability Wiring (~4 min)

**Files touched:** `app/swimmers/[id].tsx`

- PB upsert uses `mutate()` with key `pbs:{swimmerId}`
- PB list load → `useQuery("pbs:{swimmerId}", fetchPBs)`
- Delete PB uses `mutate()` with key `pbs:{swimmerId}`

**New file:** `app/components/InlineError.tsx` — small red text + icon, used by all updated screens

**Success check:** PB list refetches after save, all error states visible to user.

---

## Timeout Tuning

| Query type                           | Default | Override                    | Rationale                                         |
| ------------------------------------ | ------- | --------------------------- | ------------------------------------------------- |
| Data reads (select)                  | 15s     | attendance stats cache: 20s | 3 parallel queries + joins on congested wifi      |
| Auth reads (getSession)              | 10s     | —                           | 10s is generous for a session check               |
| Writes (insert/update/upsert/delete) | 15s     | —                           | Writes are fast; 15s covers reconnection overhead |
| Progression chart                    | 10s     | —                           | Already using 10s; keep consistent                |

---

## Risks & Non-Goals

### Not In Scope

- **Offline-first / optimistic UI** — beyond MVP
- **React Query / TanStack Query** — adds dependency; the in-memory Map cache handles the use cases here
- **Supabase Realtime subscriptions** — not in use
- **Sentry / error reporting** — logging function is future-ready but not wired yet

### Known Risks

1. **Cache leak in `useQuery`:** Map grows unbounded. Mitigation: after 50 keys, evict the oldest 25 on each new insertion. Acceptable for app scale.

2. **Focus refetch storms:** rapid tab-switching could trigger redundant fetches. Mitigation: `staleTime` (30s default) prevents redundant fetches within that window.

3. **`coachId` null at app launch:** `enabled: false` when `coachId` is null. On first focus after auth resolves, `enabled` flips true and the query fires.

4. **Auth init hardening:** if `getSession()` times out, the app shows the loading spinner longer — but it fails visibly rather than silently with null coachId.

---

## Success Criteria

After all 6 chunks:

- Zero bare `await supabase.from(...)` calls remain in the app
- Every Supabase call has a timeout
- Every screen shows a user-facing error state (not spinner-forever or silent empty) on failure
- The 3 write→read gaps show fresh data on return without manual pull-to-refresh
- `npm run typecheck` passes on every chunk

---

## Files Changed Summary

| Chunk | Files                                                           |
| ----- | --------------------------------------------------------------- |
| M1    | `lib/supabase-helpers.ts`, `context/AuthContext.tsx`            |
| M2    | `lib/auth.ts`, `lib/swimmers.ts`                                |
| M3    | `attendance.tsx`, `today.tsx`                                   |
| M4    | `workout/[id].tsx`, `swimmer-sheet.tsx`                         |
| M5    | `results.tsx`, `set-schedule.tsx`                               |
| M6    | `app/swimmers/[id].tsx`, `app/components/InlineError.tsx` (new) |
