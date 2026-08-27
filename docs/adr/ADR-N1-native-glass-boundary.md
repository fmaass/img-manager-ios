# ADR-N1 — Native glass boundary: system components only

**Status:** accepted (drafted WP8 P0a, 2026-08-27; mirrors img-manager ADR-0003, page
3136, "PrimeVue adoption boundary: gate-verified primitives only" — the web UI's
equivalent decision).

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
- Where chrome floats over photographs — the loupe's mark bar being the clearest case —
  the **`clear` variant** is used, which is the system's own answer to legibility over
  arbitrary imagery, not a custom tint or blur hand-picked against a sample set.
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
