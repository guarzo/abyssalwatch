# Fly.io Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy AbyssalWatch to Fly.io as a single-machine hobby app, backed by Supabase Postgres, served on a user-owned custom domain over HTTPS.

**Architecture:** One Fly app, one shared-cpu-1x machine in a single region, Phoenix release built via Docker. Postgres is external (Supabase free tier) over the transaction pooler. Secrets live in Fly. TLS terminated by Fly with a custom domain attached via `fly certs`.

**Tech Stack:** Elixir/Phoenix 1.8, Ash 3.x, Ecto/Postgres, Docker, Fly.io, Supabase.

**Spec:** `docs/superpowers/specs/2026-05-03-fly-io-deployment-design.md`

**Operator inputs needed before starting:**
- A Fly.io account with `flyctl` installed and authenticated (`fly auth login`).
- A Supabase project (created in step Task 1) and its **transaction pooler** connection string (port 6543).
- Owned domain name; access to its DNS records.
- EVE SSO `EVE_CLIENT_ID` / `EVE_CLIENT_SECRET` from CCP developer portal.
- Mutamarket API key.
- Discord webhook URL.

---

### Task 1: Provision Supabase project (manual, operator step)

**Files:** none (manual external setup).

- [ ] **Step 1: Create the Supabase project**

In the Supabase dashboard: New Project → choose a region close to your intended Fly region (e.g. `us-east-1` if you'll deploy to `iad`). Set a strong DB password and save it.

- [ ] **Step 2: Capture the transaction pooler connection string**

In Supabase dashboard → Project Settings → Database → "Connection string" → "Transaction pooler". Copy the URL. It looks like:

```
postgres://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres
```

Save it locally in a scratch file (do NOT commit). You'll paste it into Fly secrets in Task 7.

- [ ] **Step 3: Verify connectivity**

Run from your dev machine:

```bash
psql 'postgres://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres' -c 'select 1;'
```

Expected output:

```
 ?column?
----------
        1
(1 row)
```

If this fails, fix it before continuing — every later task depends on this URL working.

---

### Task 2: Generate Phoenix release artifacts

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `rel/overlays/bin/server`
- Create: `rel/overlays/bin/migrate`
- Create: `rel/overlays/bin/server.bat` (generated; ignore on Linux deploys)
- Create: `rel/overlays/bin/migrate.bat` (generated)

- [ ] **Step 1: Run the Phoenix release generator**

```bash
mix phx.gen.release --docker
```

If prompted to overwrite anything, answer **N** — there should be nothing to overwrite in this repo.

- [ ] **Step 2: Verify the generated files exist**

```bash
ls Dockerfile .dockerignore rel/overlays/bin/server rel/overlays/bin/migrate
```

Expected: all four paths print without errors.

- [ ] **Step 3: Verify the build works locally**

```bash
docker build -t abyssalwatch:local .
```

Expected: build completes successfully with a final image tagged `abyssalwatch:local`. If it fails on asset compilation, fix the Dockerfile (commonly: missing `mix assets.deploy` step — but `phx.gen.release --docker` includes it by default in Phoenix 1.8).

- [ ] **Step 4: Commit**

```bash
git add Dockerfile .dockerignore rel/
git commit -m "chore: add phoenix release docker artifacts"
```

---

### Task 3: Enable Postgres SSL in runtime config

**Files:**
- Modify: `config/runtime.exs` (the `Abyssalwatch.Repo` config inside the `if config_env() == :prod do` block)

- [ ] **Step 1: Update the Repo config to enable SSL with `verify_none`**

Find this block in `config/runtime.exs`:

```elixir
  config :abyssalwatch, Abyssalwatch.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6
```

Replace with:

```elixir
  config :abyssalwatch, Abyssalwatch.Repo,
    ssl: true,
    ssl_opts: [verify: :verify_none],
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6
```

Rationale: Supabase serves Postgres over TLS with a non-public CA. `verify_none` is the standard pattern for Supabase + Ecto (used by Fly's own deploy guides for Supabase).

- [ ] **Step 2: Sanity-check the file compiles**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile, no warnings about `runtime.exs`.

- [ ] **Step 3: Commit**

```bash
git add config/runtime.exs
git commit -m "chore: enable postgres ssl for supabase in runtime config"
```

---

### Task 4: Initialize the Fly app

**Files:**
- Create: `fly.toml`

- [ ] **Step 1: Run `fly launch` without deploying**

```bash
fly launch --no-deploy --copy-config=false
```

Answer prompts:
- App name: `abyssalwatch` (or another globally-unique name; remember whatever you pick)
- Organization: personal
- Region: pick one near your Supabase region (e.g. `iad` if Supabase is `us-east-1`)
- Postgres: **No** (we use Supabase)
- Redis / Sentry / etc.: **No**
- Deploy now: **No**

This generates `fly.toml`.

- [ ] **Step 2: Verify and adjust `fly.toml`**

Open `fly.toml` and confirm/edit it to contain:

```toml
app = "abyssalwatch"             # whatever name you chose
primary_region = "iad"            # whatever region you chose

[build]

[deploy]
  release_command = "/app/bin/migrate"

[env]
  PHX_HOST = ""                   # leave empty here; set as a secret in Task 7
  PORT = "4000"

[http_service]
  internal_port = 4000
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0
  processes = ["app"]

[[vm]]
  memory = "1gb"
  cpu_kind = "shared"
  cpus = 1
```

Notes:
- `release_command` runs migrations against Supabase before the new release boots.
- `auto_stop_machines = "stop"` + `min_machines_running = 0` lets the machine sleep when idle.
- Remove any `[mounts]` block if `fly launch` added one — we don't need a volume.

- [ ] **Step 3: Commit**

```bash
git add fly.toml
git commit -m "chore: add fly.toml for hobby deployment"
```

---

### Task 5: Generate `SECRET_KEY_BASE`

**Files:** none.

- [ ] **Step 1: Generate the value**

```bash
mix phx.gen.secret
```

Copy the 64-char output. Save in your scratch file alongside the Supabase URL.

---

### Task 6: Set Fly secrets

**Files:** none (operator step).

- [ ] **Step 1: Set every required secret in one call**

Replace each `<...>` placeholder with the real value. Use single quotes so shell metacharacters in passwords don't break things.

```bash
fly secrets set \
  SECRET_KEY_BASE='<from Task 5>' \
  DATABASE_URL='<supabase pooler URL from Task 1>' \
  PHX_HOST='yourdomain.com' \
  EVE_CLIENT_ID='<eve client id>' \
  EVE_CLIENT_SECRET='<eve client secret>' \
  EVE_CALLBACK_URL='https://yourdomain.com/auth/eve/callback' \
  MUTAMARKET_API_KEY='<mutamarket key>' \
  DISCORD_WEBHOOK_URL='<discord webhook url>'
```

- [ ] **Step 2: Verify secrets are present**

```bash
fly secrets list
```

Expected: all eight secret names listed (digests shown, values not). If any are missing, re-run `fly secrets set` for just that one.

---

### Task 7: First deploy

**Files:** none.

- [ ] **Step 1: Deploy**

```bash
fly deploy
```

Expected: build runs, image pushes, `release_command` runs `bin/migrate` (you'll see Ecto migration logs), one machine starts, healthcheck passes on port 4000.

- [ ] **Step 2: Verify the app is running**

```bash
fly status
```

Expected: one machine in state `started`, healthchecks passing.

- [ ] **Step 3: Hit the fly.dev URL to confirm boot**

```bash
curl -sI https://<your-app-name>.fly.dev/ | head -1
```

Expected: `HTTP/2 200` (or a redirect to HTTPS, then 200). At this stage SSO callback won't work yet — login UI loading is enough.

- [ ] **Step 4: If anything failed, read logs and fix before continuing**

```bash
fly logs
```

Common failures:
- `DATABASE_URL` wrong or SSL not enabled → revisit Task 3 / Task 6.
- Migration failure → fix the migration locally, redeploy.
- Boot timeout → check `PHX_HOST` is set; check the endpoint config block.

---

### Task 8: Attach the custom domain

**Files:** none.

- [ ] **Step 1: Add the cert on Fly**

```bash
fly certs add yourdomain.com
```

Output includes the DNS records you need to set (A and AAAA, plus an `_acme-challenge` CNAME if using a non-apex hostname or if Fly requests it).

- [ ] **Step 2: Set DNS records at your registrar**

Add the A and AAAA records (and CNAME if requested) exactly as `fly certs add` printed them. TTL 300 is fine.

- [ ] **Step 3: Wait for cert issuance and verify**

```bash
fly certs show yourdomain.com
```

Expected eventually: `Configured = true`, `Issued = true`. May take 1–10 minutes after DNS propagates.

- [ ] **Step 4: Verify HTTPS works**

```bash
curl -sI https://yourdomain.com/ | head -1
```

Expected: `HTTP/2 200` with a valid cert (no `--insecure` needed).

---

### Task 9: Update EVE SSO callback

**Files:** none (manual external setup at developers.eveonline.com).

- [ ] **Step 1: Update the callback URL on the EVE application**

In the CCP developer portal, edit your AbyssalWatch application and set the callback URL to:

```
https://yourdomain.com/auth/eve/callback
```

Save. EVE SSO will reject the OAuth flow if the callback URL on the app doesn't exactly match the `redirect_uri` the app sends (which `runtime.exs` builds from `EVE_CALLBACK_URL`).

---

### Task 10: Smoke test in production

**Files:** none.

- [ ] **Step 1: Verify EVE SSO login**

Visit `https://yourdomain.com/`, click Login, complete EVE SSO. Expected: redirect back to the app, logged in as your character.

- [ ] **Step 2: Verify Mutamarket search**

Run an abyssal module search from the SearchLive page. Expected: results render. Then refresh and run again — expect a faster response (ETS cache hit).

- [ ] **Step 3: Verify ESI fittings load**

Open `/esi/fittings` (or whatever the ESI fittings route is). Expected: your character's fittings list loads.

- [ ] **Step 4: Verify Discord webhook**

Create a watchlist that should match an existing module. Wait for the next `Watchlists.Monitor` tick (or trigger a manual match if the app exposes one). Expected: a message lands in the configured Discord channel.

- [ ] **Step 5: Verify migrations ran**

```bash
fly logs | grep -i "migrated\|migration"
```

Expected: lines showing your migrations applied during the release_command.

- [ ] **Step 6: Verify auto-stop**

Stop hitting the app for ~5 minutes, then `fly status`. Expected: machine state transitions to `stopped`. Hit the URL again — first request takes 1–2s extra (cold start), then normal.

---

### Task 11: Final cleanup commit

**Files:** none new (this confirms the working tree is clean).

- [ ] **Step 1: Confirm working tree is clean**

```bash
git status
```

Expected: `nothing to commit, working tree clean`. If anything is pending, decide whether it belongs in the deployment work or is unrelated, and either commit it or stash it.

- [ ] **Step 2: Push the branch and open a PR (optional)**

If working on a branch (this plan was authored on `guarzo/prep`):

```bash
git push -u origin HEAD
gh pr create --title "Deploy to Fly.io" --body 'See docs/superpowers/specs/2026-05-03-fly-io-deployment-design.md'
```

---

## Self-review notes

- **Spec coverage:** every section of the spec is covered — Architecture (Tasks 4, 7), Files added/changed (Tasks 2, 3, 4), Secrets (Tasks 5, 6), Rollout order (Tasks 1–10), Verification (Task 10).
- **Placeholders:** none — every command is concrete; only operator-supplied values (passwords, keys, domain) are angle-bracketed by design.
- **Type consistency:** N/A (no Elixir API surface added; only config + deploy artifacts).
- **TDD:** intentionally not used — this plan is pure deploy/config work where the "test" is the live smoke check in Task 10. There is no business logic added that warrants ExUnit coverage.
