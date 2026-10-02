# ADR-N1 — Native glass boundary: system components only

**Status:** accepted, amended 2026-10-02 (drafted WP8 P0a, 2026-08-27; mirrors img-manager
ADR-0003, page 3136, "PrimeVue adoption boundary: gate-verified primitives only" — the web
UI's equivalent decision; Amendment 1 below replaces the clear-variant clause).

## Context

img-manager-ios ships as a household-distributed SwiftUI app on iOS/iPadOS 26+, the
first OS generation to carry Liquid Glass as a system material. The design round
([/link/3220](/link/3220) §7.4, accepted by the owner as decision
5 in the WP8 plan) considered building custom glass surfaces for the loupe's mark bar and
similar chrome: the most native-feeling look, achieved by hand-tuning `glassEffect`
parameters against arbitrary photographs.

That was rejected. Two reasons, both load-bearing:

1. **Legibility risk.** A photograph is uncontrolled content behind the glass — unlike a
   fixed background a designer picks once, every image in the library is a different
   test case for contrast and readability. Hand-tuning against a representative sample
   does not generalize to the next 36,000 photos the household imports.
2. **A moving target.** iOS 27 is expected to refine the Liquid Glass material itself,
   with no code change required from apps that use the system components as-is. Hand-
   tuned custom glass would need to be re-tuned against a material Apple keeps adjusting
   — tuning effort spent fighting a target that will not sit still.

## Decision

**System components only, in every phase of this app, without exception:**

- Every glass-bearing surface (mark bar, toolbars, sheets, menu-bar chrome) uses Apple's
  system components (`.glassEffect` supplied only through system-provided controls —
  `Toolbar`, `NavigationSplitView` chrome, system button styles — never invoked directly
  on custom content).
- ~~Where chrome floats over photographs — the loupe's mark bar being the clearest case —
  the **`clear` variant** is used, which is the system's own answer to legibility over
  arbitrary imagery, not a custom tint or blur hand-picked against a sample set.~~
  *Amended by Amendment 1 (2026-10-02), below: chrome sits on Regular glass, the system
  default, everywhere; Clear is not selected anywhere.*
- **No custom `glassEffect` surface exists anywhere in the shipped app, in v1.** This is
  a hard boundary, not a starting position to be relaxed as screens get built: every
  phase's premise gate carries it as invariant (iii) ("no glass in the content layer"),
  and the WP8 plan's own Acceptance Criteria require it verified before release ("no
  custom `glassEffect` surface exists in the shipped app").
- The content layer itself — grid cells, the loupe image, inspector rows — carries no
  glass treatment at all. Glass is chrome-only.

## Consequences

- **What this buys:** legibility that tracks the system default across the whole photo
  library without per-image tuning, and zero maintenance cost when iOS 27's material
  refinement ships — the app inherits the improvement for free.
- **What this costs:** the app looks exactly as native as the system components allow,
  and no more. A bespoke, more distinctive glass treatment — if ever wanted — is future
  scope requiring its own ADR revision, not a default this one leaves open.
- **Enforcement:** the mac-gate's grep step (mirroring the estate's "a check a comment
  can defeat is not a check" doctrine, memos-ng-ios/CLAUDE.md) can check for direct
  `glassEffect(` call sites outside system-component wrappers once product screens exist
  (P3 onward); P0a's scaffold has no glass-bearing content to check yet — this ADR exists
  so the boundary is written down before the first control that could violate it.

## Mirrors

This ADR is the native-app equivalent of
[ADR-0003](/link/3136) — "PrimeVue adoption boundary:
gate-verified primitives only" — which drew the same kind of boundary for the web
Workspace UI: use the framework's own verified primitives, do not hand-roll bespoke
chrome that then has to be maintained against the framework's own evolution.

## Amendment 1 (2026-10-02)

**Ruling:** IMGMGR-470 comment 10233 (owner ruling 2026-10-02): "Regular everywhere, per p4128
D6; no device comparison; ADR-N1's Clear clause is amended."

**What changes.** The clear-variant bullet under Decision is replaced by this rule:

- Every glass-bearing surface uses **Regular glass, the system default**, everywhere in the
  app — including where chrome floats over photographs, the loupe's mark bar among them. This
  is design record p4128 D6 ([/link/4128](/link/4128)), which puts chrome on Regular glass by
  default.
- **Clear is not selected anywhere.** No view picks a glass variant of its own; each surface
  takes what its system component supplies.
- **No device comparison.** p4128 D6 left Clear with a dimming layer as a variant to test on
  a device (its open item 3). The owner closed that item without the test: there is no
  Regular-versus-Clear trial to run before or after this amendment.

**Basis.** Build 0.14.0 (20) already uses the system default (Regular) on every surface and
passed the owner's device pass. The system bars, the sidebar and the tab bar offer no
app-side variant choice in any case.

**Background extension.** `.backgroundExtensionEffect()` applied to the grid's scroll
content — so photographs continue, mirrored and blurred, under the floating iPad sidebar
(p4128 D1/D6, IMGMGR-469) — is permitted under this amendment. It is a system modifier, not a
custom glass surface: the app draws no glass of its own with it, and the sidebar above it
stays the system's own Regular glass. It is applied to content only, never to a control or
the toolbar.

**What does not change.** Everything else in this ADR stands: system components only, no
custom `glassEffect` surface anywhere in the shipped app, and no glass treatment in the
content layer. The mac-gate's `no-custom-glass-grep` leg enforces the same boundary as
before.
