# Test Coverage Audit — Design

**Date:** 2026-05-03
**Status:** Spec
**Goal:** Produce a prioritized, risk-rated audit of test coverage across `lib/abyssalwatch/` and the project's external-API client modules. **No tests are written as part of this work** — the deliverable is the audit document itself, which becomes the input to a follow-up implementation plan.

---

## 1. Motivation

The project was paused mid-development. Existing test coverage is sparse: only `optimization/engine_test.exs` and `fittings/parsers/eft_test.exs` exercise non-trivial logic. Before resuming feature work, we need a clear picture of where the risk is concentrated so future test investment can be targeted rather than scattershot.

This audit is the planning artifact. It does not write tests. It produces a ranked list and a rationale that a later session (or human) can execute against.

## 2. Scope

**In scope** (per brainstorming choice C — domain + integration boundaries):

- All modules under `lib/abyssalwatch/` (Accounts, Market, Watchlists, Fittings, Optimization, Preferences, supporting infra).
- External-API client modules called out as their own category, regardless of domain location:
  - Mutamarket client / cache / rate limiter
  - Discord webhook client + message builder
  - ESI fittings client
  - EVE SSO (`eve_auth.ex`)

**Out of scope:**

- `lib/abyssalwatch_web/` — LiveViews, controllers, plugs, components. Listed in an appendix with a one-line "why skipped" so the omission is explicit, not forgotten.
- Generated/scaffolded files (`endpoint.ex`, `telemetry.ex`, `mailer.ex`, `gettext.ex`).
- Migration files.

## 3. Output

A single markdown document committed to the repo at:

```
docs/test-coverage-audit-2026-05-03.md
```

The audit doc is not a spec — it's a reference artifact. It lives next to other project docs (`PRD.md`, `IMPLEMENTATION_PLAN.md`).

## 4. Document structure

The audit doc itself has these sections:

### §1 Summary
One paragraph. Total modules audited, count by risk tier, count of integration boundaries with no tests, headline recommendation.

### §2 Methodology
- How modules were enumerated (find under `lib/abyssalwatch/`, plus the four integration boundaries).
- What counts as "tested": a test file that exercises at least one public function on the module, asserting on observable behavior (not just `assert is_map(result)`).
- Risk rubric (see §5 below).
- Effort rubric (see §5 below).
- Acknowledged limitations: this is a static read of the source plus existing tests; runtime behavior, flaky-test patterns, and integration-test gaps that span multiple modules are not assessed.

### §3 Integration Boundaries
Highest priority. One subsection per boundary. Each subsection lists the relevant module(s) with the per-module entry shape from §6.

Boundaries to cover:
1. Mutamarket (`market/mutamarket/{client,cache,rate_limiter}.ex`)
2. Discord (`watchlists/discord/{client,message_builder}.ex`)
3. ESI Fittings (`fittings/esi/client.ex`)
4. EVE SSO (`accounts/eve_auth.ex`)

For each boundary, also note: the HTTP library used (Req vs other), whether responses are validated against a schema, what happens on vendor 4xx/5xx, and the smallest possible mock surface for tests.

### §4 Domain Logic by Ash Domain
One subsection per Ash domain, with per-module entries:

- **Accounts** — `accounts.ex`, `notification_settings.ex`, `secrets.ex`, `token.ex`, `user.ex`, `user/*`
- **Market** — `market.ex`, `resources/{module,module_type}.ex`, `scoring/{topsis,criteria}.ex`
- **Watchlists** — `watchlists.ex`, `monitor.ex`, `matcher.ex`, `notifier.ex`, `resources/{watchlist,notification}.ex`
- **Fittings** — `fittings.ex`, `parsers/{eft,dna,xml}.ex`, `resources/fitting.ex`
- **Optimization** — `optimization.ex`, `engine.ex`, `types.ex`, `solvers/{behaviour,heuristic,constraint}.ex`
- **Preferences** — `preferences/store.ex`

### §5 Prioritized Backlog
A single ranked table pulling the top ~15 entries from §3 and §4. Columns:

| Rank | Module | Risk | Effort | One-line rationale |
|------|--------|------|--------|---------------------|

Sort: risk descending, then effort ascending (cheap high-risk wins first). This section is the "what to do first" cheat sheet — a reader who skips everything else should still be able to act on it.

### §6 Test Infrastructure Gaps
Not modules — patterns and tooling that need to exist before test writing is efficient. Examples to investigate:

- Is there a Req mock layer? (`Req.Test` plug, or hand-rolled stub module?)
- Are there fixture files for Mutamarket / Discord / ESI responses, or do tests need to capture them?
- Is there a factory pattern for Ash resources, or do tests build structs by hand?
- Is `Mox` set up for behaviour-based mocking?
- Are async tests safe (sandbox + each integration client respects test config)?

Each gap entry: one sentence on what's missing, one sentence on what unblocks.

### §7 Appendix: Skipped surface
List of `lib/abyssalwatch_web/` files with one-line "why skipped" so the omission is explicit. Also lists scaffolded/generated files excluded from §3-§4.

## 5. Risk and effort rubrics

**Risk:**

- **High** — bugs change user-visible output silently (scoring, matching, parser correctness), OR external-API contracts that break on vendor changes without producing loud errors.
- **Medium** — bugs produce observable failures (crashes, error logs) but blast radius is bounded to one feature.
- **Low** — thin wrappers, pure data plumbing, code already exercised transitively by adjacent tests.

**Effort:**

- **S** — under 1 hour. Single module, simple inputs/outputs, no fixtures needed.
- **M** — 1–3 hours. May need fixtures or property tests.
- **L** — 3–8 hours. Multiple modules, mock setup, integration-style tests.
- **XL** — over 1 day. Major infra work or large surface area.

## 6. Per-module entry shape

Every module entry in §3 and §4 follows this exact format for consistency:

```
### `lib/abyssalwatch/<path>.ex`
- **Coverage:** None | Partial (test file: `path/to/test.exs`) | Full
- **Risk:** High | Medium | Low — <one-sentence rationale>
- **Suggested tests:** <test type(s) and what they'd cover, 1-3 sentences>
- **Effort:** S | M | L | XL
```

If a module has notable testability concerns (e.g., GenServer with no public API for state inspection, hard-coded `DateTime.utc_now/0`, etc.), add a fourth bullet:

```
- **Notes:** <concern, 1 sentence>
```

## 7. Methodology for performing the audit

This is not part of the deliverable doc — it's the process for producing it.

1. Enumerate modules: `find lib/abyssalwatch -name "*.ex"`.
2. For each module: read the source, check `test/` for matching files, classify per the rubrics in §5.
3. For integration boundaries, additionally inspect: HTTP library used, error handling on non-200 responses, retry/backoff behavior, what's logged on failure.
4. After all entries are written, sort §5 backlog by risk desc, effort asc.
5. Spot-check 3-4 entries against the live code to catch classification drift partway through.
6. Run the spec self-review checklist on the produced doc.

## 8. Non-goals

- Writing any tests.
- Fixing any bugs found during the audit (note them in the doc; don't fix).
- Reviewing test quality of the two existing test files (separate concern; if they're missing assertions, that's a follow-up).
- Estimating total project test-coverage time — the prioritized backlog is the unit of planning, not a project-level budget.

## 9. Success criteria

- The audit doc exists at `docs/test-coverage-audit-2026-05-03.md`.
- Every module in `lib/abyssalwatch/` is accounted for (either has an entry or appears in §7 appendix with a reason).
- The §5 backlog is actionable: a person could pick rank #1 and start writing tests without re-reading the rest of the doc.
- The §6 infra gaps section identifies any blockers that would make the §5 backlog inefficient to execute.
