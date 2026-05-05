# UI Review — Search / Optimize / Watch

Date: 2026-05-04
Scope: review of `optimize.jpg`, `search.jpg`, `watch.jpg` and recommendations.

## Overall

Solid functional dark UI with a Pokémon-game-style sidebar, but the visual language feels generic "AI dashboard cyan" and there's significant unused real estate.

---

## 1. Search (strongest of the three)

**What works**
- Filter chips at top (Stat Filters, Active Filters) communicate state cleanly
- Result cards have good information density without feeling cramped
- Sidebar nav is clear

**Problems**
- **Three "+ Add Filter" buttons stacked** is repetitive and noisy. Collapse into a single command (one "Add filter" pill that opens a popover with categorized stats).
- **Zero visual hierarchy in the result grid** — every card is identical weight. Score is buried. Make Score the dominant visual (large numeral, color-coded heatmap by tier: 90+ = green glow, 80–89 = amber, etc.)
- **Stat rows inside cards are flat lists**. Use micro bars or sparklines showing where each stat sits in the population distribution.
- "+ Add Filter" empty pills with no border feel unfinished — dashed border + ghost icon.

---

## 2. Optimization (biggest opportunity)

**What works**
- Top-level "Best Combinations" KPI is good
- Two-column layout reads well

**Problems**
- **Massive empty space below the fold**. The "Best Combinations" panel collapses to nothing when empty — instead, show a sample/illustrative combo with "Add modules to see real results" overlay. Empty states should *teach*.
- **Stat sliders on the right are visually dead weight** — just labels and dashes. Either:
  - Show the actual current min/max/median across selected modules with a distribution strip, OR
  - Hide until modules are selected
- **"Selected Modules (0)"** is begging for a drag-and-drop affordance or a dotted dropzone, not a flat panel.
- The "Find Best Fitting" CTA is the most important action but is visually small. Make it large, sticky, disabled-with-reason ("Select at least 2 modules") until ready.
- **TOPSIS scoring is the secret weapon** — surface what it means (tooltip, side panel) so users trust the rankings.

---

## 3. Watchlists (most generic, needs the most work)

**What works**
- Clear "Create Watchlist" CTA
- Tab structure (My Watchlists / Recent Matches / Settings)

**Problems**
- **Page is 80% empty space** with one card floating in the middle. Even in empty state:
  - Show a sample watchlist card preview with explanation
  - Show recent community matches as social proof
  - Show a "templates" row (e.g. "Track all 10/10 invuls under 500M ISK")
- **The single watchlist card has no preview of what it's watching** — show matching criteria as filter chips, last match time, # of matches today, a sparkline of activity.
- Discord webhook integration is a killer feature — surface it. A small "🔔 Discord connected" indicator on each card builds confidence.
- Tab pills could have counts: "Recent Matches (12)".

---

## Unifying Visual Direction

The current aesthetic is generic "AI startup dashboard cyan-on-near-black". EVE Online has a strong visual identity — neon plasma, Abyssal mutaplasmid color tiers (Gravid / Decayed / Unstable), holographic UI from the in-game client. Lean into it.

| Element | Current | Suggested |
|---|---|---|
| Font | Generic sans (Inter-ish) | Display: **Orbitron** / **Audiowide**; Body: **Rajdhani** / **JetBrains Mono** |
| Background | Flat `#0a0e1a` | Layered: deep navy + subtle nebula gradient + 1% noise overlay |
| Accent | Cyan everywhere | Tier-based: Gravid magenta, Decayed cyan, Unstable amber — color carries meaning |
| Card chrome | Flat rounded rect | 1px gradient border + inner glow on hover; angular cuts on corners (EVE chamfer) |
| Numeric values | Same weight as labels | Tabular monospace, larger, glowing on best values |
| Empty states | Blank | Holographic outline placeholder with hint text |

---

## Priority order

1. **Optimization page empty state** + visible CTA hierarchy (highest ROI)
2. **Search results visual hierarchy** — Score as hero, distribution context
3. **Watchlists card preview** — show what's being watched, recent activity
4. **Filter UI consolidation** on Search
5. **Aesthetic pass** — typography + tier-based color system
