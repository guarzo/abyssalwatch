# Design

## Visual Theme

**Cool slate, restrained.** A dark, low-chroma desk-side instrument. Neutrals tilt slightly cool (hue 250) to read as quiet graphite without echoing EVE's in-game UI. One muted-indigo accent (hue 280), used only for primary action, focus, and active selection. Hierarchy comes from scale and weight, not from glow or color shift. Every numeric column is tabular.

Single dark theme. No light mode. The scene sentence — *"pilot at a desk, second monitor next to a game window, dim room, glancing for one fact and putting the app down"* — forces dark, and switching modes is dead weight in a tool with this scene.

## Color Palette

OKLCH only. Surface hue 250 (cool slate), accent hue 280 (muted indigo), status palette functional only.

```css
:root {
  /* Surface — cool slate, hue 250, near-zero chroma.
     Tier spread is wide on purpose: panels must visibly sit on the page,
     not in it. Don't compress these values back together. */
  --surface-0:    oklch(0.13 0.005 250); /* app background */
  --surface-1:    oklch(0.18 0.005 250); /* default panel */
  --surface-1-5:  oklch(0.205 0.006 250); /* zebra stripe alternate row */
  --surface-2:    oklch(0.23 0.006 250); /* hover row, sticky header */
  --surface-3:    oklch(0.30 0.008 250); /* active row, popover */
  --surface-overlay: oklch(0.08 0.004 250 / 0.65);

  /* Ink — warm-leaning whites, hue 80, very low chroma (slight warmth against cool surface) */
  --ink-1: oklch(0.96 0.005 80); /* primary text, headings, numbers */
  --ink-2: oklch(0.78 0.006 80); /* body */
  --ink-3: oklch(0.58 0.007 80); /* meta, units, helpers */
  --ink-4: oklch(0.42 0.007 80); /* disabled */

  /* Borders — 1px hairlines, never decorative.
     `--rule-1` is the default in-section divider; bump to `--rule-strong`
     for the band that separates Filters / Results / Detail. */
  --rule-1:      oklch(0.38 0.006 250);
  --rule-2:      oklch(0.46 0.007 250);
  --rule-strong: oklch(0.58 0.009 250);

  /* Accent — muted indigo, hue 280 */
  --accent: oklch(0.72 0.13 280);
  --accent-strong: oklch(0.80 0.14 280);
  --accent-soft: oklch(0.72 0.13 280 / 0.18);
  --accent-ink: oklch(0.18 0.01 280);

  /* Status — moderate chroma; always paired with shape glyph + label */
  --status-ready:    oklch(0.78 0.13 145); /* ● green   */
  --status-training: oklch(0.85 0.13  95); /* ◐ yellow  */
  --status-queued:   oklch(0.74 0.10 240); /* ▸ blue    */
  --status-idle:     oklch(0.58 0.005 250); /* ○ neutral */
  --status-error:    oklch(0.70 0.18  25); /* ! orange  */

  --motion-duration-fast: 120ms;
  --motion-duration-base: 180ms;
  --motion-ease: cubic-bezier(0.2, 0, 0, 1);

  color-scheme: dark;
}
```

`--ink-1` on `--surface-1` measures ~14:1, `--ink-3` on `--surface-1` ~4.6:1. AA without thinking.

## Typography

- Body / UI: **Inter** 400 / 500 / 600.
- Mono / numerals: **JetBrains Mono** 400 / 500. Used for ISK figures, percentages, attribute values, identifiers, every numeric column.
- `font-feature-settings: 'tnum'` on numeric columns.

Scale (1.25 ratio). **Letter-spacing is the third hierarchy lever** — without it, headings and body collapse into the same visual weight. Don't drop it.

| Step | Size / line-height | Weight | Letter-spacing | Use |
|---|---|---|---|---|
| display | 28 / 36 | 600 | -0.012em | Page title, one per page |
| h2 | 22 / 30 | 600 | -0.008em | Section heading |
| h3 | 17 / 24 | 600 | -0.005em | Group header |
| body | 14 / 20 | 400 | 0 | Default |
| meta | 12 / 16 | 500 | +0.06em, **uppercase** | Column headers, section labels, group sublines |
| micro | 11 / 14 | 500 | +0.04em | Shortcut hints, breadcrumbs |

The uppercase + tracked `meta` step is what makes a column header read as a *label* rather than another row of data. Apply it consistently to table headers and the small labels above grouped fields.

Body line length 65–75ch.

## Spacing & rhythm

4px base. Allowed: **4 / 8 / 12 / 16 / 20 / 24 / 32 / 48 / 64**. Never 6 / 10 / 14 / 18.

Density tiers:

- Dense rows (module tables, watchlist matches): 40px row, 8px vertical / 16px horizontal padding, tabular numerals, **alternating `--surface-1` / `--surface-1-5` zebra striping**.
- Comfortable rows (fittings, watchlists): 48px row, 12px vertical, no zebra.
- Reading layout (settings, instructions): max-width 65ch, line-height 1.55.

### Section breaks

Within a panel: hairline `--rule-1` between rows or grouped fields.

Between *sections* of a page (Filters / Results / Detail; sidebar / content; nav / page): `--rule-strong` 1px band, 16-24px vertical breathing room. The strong rule is what tells the eye "this is a different surface of the application." Don't substitute another hairline.

### Surface noise (allowed exception)

`--surface-0` (the app canvas only) carries a fixed-position 1.5% SVG noise overlay. This fights the dead-flat look of pure dark surfaces without violating the no-decoration rule — the noise reads as instrument-panel texture, not as glow or chrome. Implementation: inline data-URI SVG on `body::before`, `position: fixed`, `inset: 0`, `pointer-events: none`, `opacity: 0.015`, `mix-blend-mode: overlay`.

Never apply noise to surface-1, -2, or -3. Never animate it.

## Radius

| Token | Value | Use |
|---|---|---|
| `--radius-sm` | 4px | Status pill, badge, chip |
| `--radius-md` | 6px | Buttons, inputs, segmented controls |
| `--radius-lg` | 10px | Surface panels, popovers, modals |

No `rounded-2xl`. No `rounded-full` chrome. (Avatars excepted.)

## Elevation

No shadow system. Layering = surface tier (`--surface-0/1/2/3`) + 1px hairline. Shadows reserved for popovers and modals only:

- Popover: `0 6px 20px oklch(0 0 0 / 0.4)`
- Modal: same.

Cards do not cast shadows.

## Motion

Functional only. Cap **180ms**. Easing **ease-out-quart** (`cubic-bezier(0.2, 0, 0, 1)`). Allowed: row expand/collapse, popover/drawer/modal opacity + 4px translateY entry, focus ring fade, refresh-icon liveness pulse. Reduced motion collapses to instant.

## Focus

```css
*:focus { outline: none; }
*:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
  border-radius: 2px;
}
```

For row focus, prefer an inset rail: `box-shadow: inset 2px 0 0 var(--accent)`. Never a colored `border-left` greater than 1px.

## Components

- **Button.** 32px (`btn-md`) default, 28px compact. Radius 6px. Primary = surface-2 with `--ink-1` text, 1px `--rule-2` border, hover lifts to surface-3 + `--rule-strong`; primary-strong = `--accent` fill with `--accent-ink` text. No gradient. No hover-lift transform. No glow.
- **Input.** 32px height, surface-1 background, 1px `--rule-2` border, focus = accent outline. Label sits above on its own line; no floating labels.
- **Table.** Hairline `--rule-1` between rows. Sticky header = surface-2. Hover row = surface-2. Selected row = surface-3 with inset accent rail. Tabular numerals.
- **Card / panel.** Surface-1 background, 1px `--rule-1` border, radius 10px. No nesting. No shadow.
- **Badge / status pill.** Surface-2 background, 1px `--rule-1` border, radius 4px. Status badges include shape glyph + label, never color alone.
- **Modal.** Surface-1 over surface-overlay scrim. Radius 10px. Modal-shaped shadow only here. Use sparingly — exhaust inline / progressive alternatives first.

## Accent placement

The indigo accent (`--accent`) earns its place by being *rare and steady*. Currently allowed:

- **Focus ring** on every focusable element.
- **Active row** in tables: `--surface-3` background + 2px `inset 2px 0 0 var(--accent)` rail (left edge, never a colored border).
- **Active nav item** (top bar or side nav): same inset rail treatment, or a 1px bottom shadow `inset 0 -1px 0 var(--accent)` for top bars.
- **Active sort column** in tables: header *label* gets `color: var(--accent)`; the cells stay `--ink-1`.
- **TOPSIS score column**: when score ≥ 0.85, the value renders in `--accent-strong`. Below threshold stays `--ink-1`. Color encodes "this is a strong match," nothing else.
- **Live indicators**: a 4px round dot in `--accent` for actively-monitoring watchlists; switches to `--status-idle` ○ when paused.
- **Primary action** button fill (`btn-primary`): `--accent` background, `--accent-ink` text.
- **Brand mark** in the topbar.

Never used decoratively. Never as a gradient. Never as a glow halo. If you want emphasis somewhere not on this list, ask whether weight or position can do the work first.

## Iconography

Heroicons outline at 20px default, 16px in row context. No emoji in chrome. Status indicators use Unicode shape glyphs (●◐▸○!) so screen readers and color-blind users get meaning without color.

## Absolute Bans

- Glassmorphism (`backdrop-filter: blur`) as default surface
- Gradient text, gradient buttons, gradient borders
- `box-shadow` for decoration; cards never cast shadows
- Hover-lift (`translateY(-Xpx)`), `hover:scale`, spring overshoot
- Side-stripe colored borders
- `rounded-2xl` everywhere, `rounded-full` chrome
- Display fonts (Orbitron and friends)
- Float / shimmer / glow / pulse infinite ambient animations
- Modals as the first thought
- Identical card grids of icon + heading + text
- Hero-metric template (big number + small label + supporting stats + accent gradient)
- Em dashes in copy (use commas, colons, semicolons, periods, parentheses)
- Light mode (single dark theme by design)
- daisyUI default classes (`btn`, `card`, `menu`, `alert`, `bg-base-*`, etc.)

### One bounded exception

A 1.5%-opacity, fixed-position SVG noise overlay on `--surface-0` only. See "Surface noise" under Spacing & rhythm. This is the *only* texture allowed anywhere in the system; it is not a license to add subtle gradients, glows, or grain to anything else.

## Copy voice

Three words: **precise, calm, expert.** "Sabre: ready in 3d 14h" beats "🚀 You're almost there!". No exclamation marks, no marketing energy.
