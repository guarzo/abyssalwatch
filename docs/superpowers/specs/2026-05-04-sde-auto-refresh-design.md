# SDE Auto-Refresh — Design

**Date:** 2026-05-04
**Status:** Approved, ready for implementation plan
**Branch:** `sde-auto-refresh` (worktree at `.worktrees/sde-auto-refresh`)

## Problem

`Abyssalwatch.Market.ModuleType` is seeded from EVE Online's Static Data Export
(SDE). Today, seeding is manual via `Abyssalwatch.Release.seed/1` and has four
problems on Fly.io:

1. SDE files in `/tmp/sde/` are wiped on every machine restart.
2. Multi-machine deploys require uploading SDE to every machine.
3. The current `Loader` builds four full in-memory maps from the SDE JSONL
   files, OOM-killing the 1 GB Fly machine (last attempt: SIGKILL after ~30s
   of `Jason.decode`).
4. There is no signal when CCP publishes a new SDE.

## Goals

- App refreshes the SDE on its own at boot, with no operator action.
- Memory-bounded: never hold the full type catalog in RAM. Stream throughout.
- Multi-machine safe: only one Fly machine downloads at a time.
- Boot-resilient: any failure (network, parse, upsert) logs and falls back to
  whatever's already in the DB. The app boots even if EVE's CDN is down.
- Manual override (`Release.seed/1`) still works.

## Non-goals

- No Fly volumes (keep ephemeral storage; streaming makes this fine).
- No Oban or new long-running schedulers. Boot-time check is enough.
- No periodic mid-uptime re-check. Operators redeploy if they need a fresh SDE
  before the next reboot.

## Investigation results

- **CCP serves `Last-Modified`, `ETag`, and `x-sde-build-number`.** Verified by
  `curl -I https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip`.
  The latest URL 302-redirects to a build-numbered URL
  (`…-3328718-jsonl.zip`); the `x-sde-build-number` header on the redirect is
  a stable monotonic integer. **We use `build_number` as the primary marker;
  ETag is recorded as a tiebreaker but not consulted for equality.**
- **Streaming unzip works in pure Elixir.** Erlang's `:zip` lets us open the
  archive once and pull individual entries by name. The 80 MB zip is written
  to a tmp file (`:zip` needs random access), then entries are streamed out
  one at a time. No `unzip` binary needed.
- **Async refresh, not blocking boot.** Blocking boot for ~30–60s of
  download+parse breaks Fly health checks. Async lets the app come up
  immediately serving the last-known DB rows; refreshed rows become visible
  as upserts commit. The rare "first-ever boot, no data" case is acceptable
  (dropdowns empty for ~1 min, once per environment).

## Architecture

```
Application.start
  └─ Supervisor
       ├─ (existing children…)
       └─ Task.Supervisor (existing or new — decide in plan)
            └─ {Task, Abyssalwatch.Market.SDE.Refresher, :run, []}
                  ├─ HEAD latest URL → build_number, etag, last_modified
                  ├─ SDE.Version.get_marker  → compare build_number
                  ├─ if equal:    log "up to date" and exit :normal
                  ├─ if different:
                  │     ├─ pg_advisory_lock(<constant key>)
                  │     ├─ re-read marker (peer node may have refreshed)
                  │     ├─ if still stale:
                  │     │     ├─ Req.get!(into: tmp_path)
                  │     │     ├─ :zip.zip_open(tmp_path, [:memory? no — file-backed])
                  │     │     ├─ Seeder.seed_streaming(zip_handle)
                  │     │     └─ Version.upsert(build_number, etag, last_modified, seeded_at, type_count)
                  │     └─ pg_advisory_unlock
                  └─ rescue/catch → Logger.warning, exit :normal
```

### Components

1. **`Abyssalwatch.Market.SDE.Version`** — new Ash resource backed by a
   single-row Postgres table.

   Attributes:
   - `id` (integer, always `1` — single-row enforced via primary key default)
   - `build_number` (integer, required)
   - `etag` (string, optional)
   - `last_modified` (utc_datetime, optional)
   - `seeded_at` (utc_datetime, required)
   - `type_count` (integer, required)

   Actions: `:read`, `:upsert` (by `id = 1`).

2. **`Abyssalwatch.Market.SDE.Refresher`** — module with `run/0` invoked as a
   one-shot `Task` from the supervision tree.

   - HEADs the SDE URL via `Req` with `redirect: false` so we capture the
     `x-sde-build-number` from the 302.
   - Acquires advisory lock with `Repo.query!("SELECT pg_advisory_lock($1)", [key])`,
     where `key = :erlang.phash2(:sde_refresh)` (constant per release).
   - Downloads with `Req.get!(url, into: File.stream!(tmp_path))` so the body
     is streamed to disk, never accumulated in memory.
   - Cleans up tmp file in an `after` block.
   - Releases lock in an `after` block.
   - Top-level `try` traps all exceptions; logs with `Logger.warning` and
     exits `:normal`.

3. **`Abyssalwatch.Market.SDE.Loader`** — rewritten.

   - Removes `read_index/2` (the OOM source) and the `load_*` functions that
     return full maps.
   - New API: `stream_entry(zip_handle, filename) :: Stream.t(map)` — opens
     a zip entry as a binary, splits on `\n`, decodes each JSON line lazily.
     Malformed lines log a warning and are skipped (preserves current
     behavior).
   - Helper `with_archive(path, fun)` opens/closes the zip handle.

4. **`Abyssalwatch.Market.SDE.Seeder`** — internals rewritten, public API
   preserved for `Release.seed/1`.

   - `seed_from_sde/1` keeps signature; new implementation does **three
     streaming passes** over the zip:
     1. `types.jsonl` → build two small accumulators:
        `abyssal_types :: %{type_id => type_data}` (only ~50 entries) and
        `ref_types_by_group :: %{group_id => ref_type_id}` (only the groups
        we care about, T2 published non-Abyssal). Both bounded by abyssal
        catalog size.
     2. `groups.jsonl` → keep only groups referenced by `abyssal_types` or
        `ref_types_by_group`. Tiny.
     3. `typeDogma.jsonl` → keep only entries whose `_key` is in
        `ref_types_by_group` values. Then stream `dogmaAttributes.jsonl`
        keeping only attributes referenced by those typeDogma entries.
   - Result: peak memory is the working set of ~50 abyssal types +
     small lookup maps (<5 MB), regardless of catalog size.
   - `seed_fallback/0` unchanged.

5. **`Abyssalwatch.Release.seed/1`** — unchanged; still accepts a path arg
   for the existing manual flow. Now also exposes `Release.refresh_now/0`
   that calls `Refresher.run/0` synchronously, for ops use.

### Data flow

App boots → `Refresher` task starts → if marker matches, exits in seconds
without touching the network beyond a HEAD. Otherwise downloads, streams,
upserts ~50 `ModuleType` rows by `:unique_eve_type_id`, writes
`SDE.Version` row, exits. Existing rows remain visible to LiveViews
throughout (Ash upserts don't invalidate readers).

### Failure modes

| Failure | Behavior |
|---|---|
| HEAD request fails | Log warning, exit. App uses existing DB rows. |
| Advisory lock timeout (peer holds it) | Wait (Postgres blocks). When unlocked, re-check marker; usually skip. |
| Download fails / partial | Tmp file deleted, log warning, exit. |
| Zip corrupt | `:zip.zip_open` errors, log warning, exit. |
| JSON parse error on a line | Skip line with warning (existing behavior). |
| Ash upsert error on a row | Increment error count, continue. Final tally logged. |
| `Version` upsert fails | Log warning. Marker stays stale → next boot retries. |

### Multi-machine safety

`pg_advisory_lock` blocks peers until the lock holder finishes. After
unblocking, peers re-read the marker; if the lock-holder updated it, peers
skip the download. If the lock-holder failed before updating, the next peer
retries.

## Testing

- **Unit (`Loader.stream_entry/2`):** Build a 3-line fixture JSONL, wrap in a
  zip, open with `:zip`, assert the stream yields 3 decoded maps. Add a
  fourth malformed line, assert it's skipped with a logged warning and the
  3 valid maps still come through.
- **Smoke (`Refresher`, marker matches):** Stub `Req` with `Req.Test` to
  return a HEAD response carrying the same `build_number` as the seeded
  `Version` row. Assert `Refresher.run/0` returns `:up_to_date` and no
  download function is invoked.
- **Smoke (`Refresher`, marker mismatch with stubbed download):** Stub HEAD
  to return a different `build_number`, stub the download URL to serve a
  fixture zip with 1 abyssal type. Assert one `ModuleType` upserted, marker
  updated.
- **Smoke (`Refresher`, network failure):** Stub HEAD to return 500. Assert
  task exits `:normal`, marker unchanged, no exception escapes.
- Existing `Seeder` tests stay green (public API unchanged).

## Open questions resolved

1. **Last-Modified/ETag reliability** → Both present; we use `build_number`
   instead because it's a clean monotonic integer.
2. **Streaming unzip** → `:zip` from Erlang stdlib; tmp file on disk + lazy
   entry extraction.
3. **Boot-time UX** → Async, non-blocking. App boots fast; refresh fills in.

## Out of scope

- Fly volumes (intentional — streaming makes ephemeral fine).
- Oban scheduler / periodic re-check (boot-time check covers the use case).
- UI for refresh status (operators read logs / `SDE.Version` table).

## Verification

`mix precommit` (compile --warnings-as-errors, deps.unlock --unused, format,
test) must pass before PR.
