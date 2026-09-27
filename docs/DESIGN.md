# Lockup design

## Overview

Lockup is a single-page observatory for people tracking and managing a timed Uniswap liquidity position. The implemented visual direction uses an off-white page, a forest-green introduction, a restrained lime accent and white working surfaces. A serif headline introduces the time rule; the ledger and transaction controls use system sans-serif type. This direction was inferred from the assignment rather than supplied as an approved brand system.

The main hierarchy is network and wallet, lock rule, pool facts, position ledger with swap controls, then the explanation and deployment details. Keep contract state and its freshness close to the controls it qualifies. Reuse source patterns in `web/src/App.tsx` and `web/src/styles.css`.

This file is intentionally under `docs/`. The overriding allowed paths exclude root `DESIGN.md`, despite a conflicting acceptance bullet requesting it there.

## Colors

Canonical tokens are CSS hex values in `web/src/styles.css :root`. There is one light theme.

| Token | Value | Role |
| --- | --- | --- |
| `--page` | `#f4f4ef` | Page and inset review background |
| `--surface` | `#ffffff` | Ledger, swap and standard controls |
| `--surface-muted` | `#eaece5` | Disabled controls, selected filter, icon backgrounds |
| `--text` | `#263a32` | Primary text |
| `--muted` | `#59675f` | Supporting text |
| `--border` | `#d3d9cf` | Structural dividers |
| `--control-border` | `#89968b` | Input and button boundaries |
| `--accent`, `--accent-hover` | `#dbe98b`, `#e8f39a` | Primary action; hero timing illustration and focus |
| `--accent-text` | `#263a32` | Text on primary action |
| `--hero`, `--hero-panel` | `#223a32`, `#294037` | Introduction and rule panel |
| `--hero-border`, `--hero-border-strong` | `#657b64`, `#74886d` | Rule panel and onchain badge borders |
| `--hero-text`, `--hero-muted` | `#f4f6e9`, `#c5d0bc` | Hero text levels |
| `--focus` | `#345e9c` | 3px focus ring on light surfaces |
| `--error`, `--error-bg` | `#902b25`, `#fff1ed` | Error text/border and surface |
| `--success`, `--success-bg` | `#28563e`, `#e4efdf` | Unlocked status |

Statuses always include words. Focus on the dark hero uses `--accent-hover`; standard blue focus is reserved for light backgrounds. Measured foreground/background pairs are in `frontend/browser-results.json`: primary text/page 10.98:1; muted text/page 5.39:1; muted text/white 5.95:1; hero text/hero 11.17:1; hero-muted/panel 6.97:1. These are measured solid pairs, not a claim about every possible rendering.

## Typography

The UI stack is `Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`; Inter is only a local preference and is not bundled or downloaded. Headline and explanatory display headings use `Georgia, "Times New Roman", serif`. Addresses use `ui-monospace, SFMono-Regular, Consolas, monospace`. Browser/platform font availability determines the actual face. No external font resources are required.

Root body is 16px, weight 400, line-height 1.55. `--small` is 0.8125rem (13px), `--label` 0.75rem (12px), and `--heading` 1.5rem (24px). Informational captions are at least 12px in the default size. Inputs stay at least 16px. Buttons use 600 weight; display headings use 400. The h1 uses `clamp(3rem, 5.7vw, 4.75rem)`, line-height 1.02 and -0.055em spacing, with explicit narrow-screen adjustments. h2 is 24px/1.25; the explanatory h2 is 40px/1.15 desktop, 36px narrow. h3 is 16px/1.4, reducing to 14px in position rows on mobile.

Headings balance their wrapping; paragraphs use pretty wrapping. Body explanations are bounded around 43–75ch by context. IDs and addresses wrap anywhere and remain selectable. Numeric states use tabular numerals. Liquidity abbreviations are approximate; exact values remain in native details disclosures, not only hover titles.

## Layout

`.wrap` is at most 1200px with 40px outer gutters on large screens. Content groups use 8–12px internal gaps, 16–32px between controls/components, and 48–72px between major sections. The hero has 56px horizontal and 48px vertical padding. The statistics row has three columns. `.workspace` places the ledger and swap panel in a 1.8:1 grid with a 300px minimum right column and a 32px gap. Panels start at 28px padding.

Actual breakpoints in `styles.css`:

- 68rem: outer gutters become 24px, panel spacing tightens, workspace ratio becomes 1.5:1 and position facts stack.
- 54rem: navigation moves to its own row and workspace becomes one column; position facts can use the full row again.
- 40rem: gutters become 16px, hero and statistics stack, panels use 20px padding, position facts and deployment data stack, and control rows wrap.

Layout stays in document flow: no fixed transaction bar, pinned footer or modal overlay. Long addresses are broken inside their container. Logical inline/block properties preserve sensible directionality in the structure. The product is English-only; localization and RTL have not been validated.

Screenshots and overflow checks cover 1440, 800, 390 and 320 CSS pixels. Root text enlargement to 200% at 800px was checked separately; this does not establish browser-native zoom behavior.

## Elevation & depth

Surfaces are flat, with borders communicating structure and state. There are no shadows, frosted layers or gradients. The dark hero creates the strongest section distinction. Standard surfaces are white; review and quote summaries use the page tone. No modal or sticky overlay stacking system is implemented. The skip link alone becomes fixed above content while focused.

## Shapes

`--radius` is 12px for major panels and the hero. Controls and inset summaries are 8px, the rule panel is 10px, status badges are 5px, and errors are 4px. The 36px local SVG brand mark has rounded corners. Borders are normally 1px. Focus is 3px solid with 4px offset. There are no clipped text containers or rounded decorations that mask essential text.

## Components

- `Dashboard` (`App.tsx`): wallet/network status, hero, statistics, refresh, transaction receipt status, explanations and deployment disclosure. Disconnected reads remain useful; freshness and failed reads are explicit.
- `Positions`: all/owned filter buttons using `aria-pressed`, labelled tokenId form, six-row pagination, and position cards. Each row carries status, UTC unlock time, countdown, exact details and actions only for a current wallet-owned NFT. Empty/burned positions retain their history; empty positions cannot remove liquidity.
- Inline `.review`: heading receives keyboard focus, offers protected minimums and a specific confirmation label. It is not a modal and does not trap focus. Cancelling returns to the trigger; completion returns to it if it remains, otherwise the section heading.
- `Swap`: labelled amount and slippage inputs, named direction button, quote/minimum output, ordered approval buttons and final swap button. Editing quote inputs clears the previous quote. Disabled state is native and explained in adjacent text.
- `Explorer`: full-value title and descriptive destination links; full addresses also appear in details. New-tab links use `rel="noreferrer"`.
- `ErrorNote`: persistent inline `role="alert"` with next-step context. Progress uses a polite status region; countdowns are not announced every second.
- Buttons: outlined default, `.primary` lime emphasis, `.small` compact text with minimum 44px height, `.text-button` underlined tertiary action. Filters and slippage inputs use a deliberate 40px minimum in the denser desktop pattern. Hover styles apply only to hover-capable devices.

All controls use native elements. Focus is explicit. Color/background transitions are 140ms ease-out and only enabled when reduced motion is not requested. There are no entrance animations, autoplay, drag gestures, custom selects or icon-only actions without names.

## Do's and don'ts

Start new content inside `.wrap`; use the current h2/eyebrow grouping and surface tokens. Reuse position facts and disclosure patterns for long chain values. Keep exact units and timestamps visible, pair status words with color, and put recovery instructions beside failures. Route action eligibility through verified, fresh chain state and the current wallet account.

Do not introduce another address map, treat a countdown as permission to transact, make a second filled action compete with the page's current primary action, or hide important data behind truncation alone. A future page should reuse these tokens and native component patterns; its routing must still support static gateway subpaths.

Design guidance attribution: Jakub Krehel's Better Interface, MIT, commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`. Documentation method: Paul Bakaus's Impeccable, Apache-2.0, commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`. See `frontend/ATTRIBUTION.md` for sources and the separate code license notice.
