# Product

## Register

product

## Users

EVE Online pilots running AbyssalWatch on a second monitor next to the game window. Dim room, late-evening session, eyes already adjusted to EVE's own UI. They glance at the app for a single fact (is this module worth bidding on, did my watchlist hit, what fits this slot best) and put it down. The same pilots also run longer sessions to build fits, score modules, optimize end-to-end, and tune watchlists — but never in marketing-energy mode. They are domain-fluent: terms like mutaplasmid, TOPSIS score, slot, EFT format, ESI need no explanation.

## Product Purpose

AbyssalWatch helps EVE pilots search, score, and optimize abyssal (mutated) modules for ship fittings, and notifies them when a watchlisted module appears on the market. Success looks like: a pilot identifies a worthwhile module within seconds of opening the app, builds a fit and finds the best in-market modules for it without bouncing tabs, and trusts a watchlist alert enough to act on it.

The product serves three co-equal jobs:

1. Find and score abyssal modules (search, filtering, TOPSIS scoring).
2. Optimize ship fittings end-to-end (build a fit, score modules into it).
3. Monitor watchlists and ship Discord notifications when matches surface.

## Brand Personality

**Precise, calm, expert.** Voice is a flight manual or a senior FC's notes — directives, not encouragement. "Sabre: ready in 3d 14h" beats "🚀 You're almost there!". No exclamation marks, no marketing energy, no decorative copy. Every word earns its place. Every numeric column is tabular. The interface should feel like a desk-side instrument, not a HUD and not a SaaS dashboard.

## Anti-references

Explicitly NOT to look like:

- **Generic SaaS dashboard** — gradient heroes, hero-metric template (big number + small label + supporting stats + accent gradient), identical card grids of icon + heading + text, marketing-tone empty states.
- **Sci-fi / EVE HUD pastiche** — neon glows, hexagonal frames, faux-techy borders, cyan-on-black "computer interface" reflex, animated scanlines. The trap most EVE tools fall into.
- **Glassmorphism** — `backdrop-filter: blur` as a default surface, frosted overlays, translucent panels.
- **Game-launcher chrome** — inset bevels, gradient buttons, stylized display fonts (Orbitron and friends), launcher-style header bars.

## Design Principles

1. **Glanceable first, deep on demand.** Every primary surface answers a single question in under a second. Detail is one click away, never inline noise.
2. **Information density without claustrophobia.** Use rhythm — vary spacing across step sizes — instead of equal padding everywhere. Dense tables earn their density; reading layouts earn their air.
3. **Hierarchy through scale and weight, never through glow or color shift.** Status colors encode state; they never decorate.
4. **Trust the data.** Tabular numerals on every numeric column. Units always present. No rounded "2.4M" shorthand where a precise figure would fit.
5. **Don't compete with EVE.** The game is on the next monitor. The app is a quiet instrument; it never matches the game's chroma, never borrows its visual vocabulary.

## Accessibility & Inclusion

Functional baseline. Full keyboard navigation on every interactive surface. `prefers-reduced-motion` respected — all functional motion collapses to instant. Status is never encoded by color alone: shape glyph (●◐▸○!) plus label always accompanies state color. Tabular numerals across numeric columns to keep scan-down comparison legible. Formal WCAG targeting is not the bar, but contrast tokens are chosen so primary text passes AA on every defined surface tier.
