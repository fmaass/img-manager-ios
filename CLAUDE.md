# img-manager-ios

The native iOS/iPadOS companion of img-manager (Swift 6 / SwiftUI, XcodeGen `project.yml`, swift-testing + XCUITest). Swift builds only on the Mac host `merkur` through `bin/mac-gate.sh` — the ONLY sanctioned build/test path from this Linux checkout. TestFlight cuts follow `docs/TESTFLIGHT.md` and run in their own release session.

## BookStack Page Registry

Durable records for this project live in the img-manager book (the two clients share one project record; pages are tagged `a:project=img-manager`).

- Book: book:2597 (img-manager — Features)
- Session Reviews chapter: chapter:2795
- Lessons Learned: page:2930
- Decisions (ADRs) chapter: chapter:3073 (ADR-0004 is page:3232)
- WP21 batch plan (re-vendor v0.20.0 + Camera + edited_count + archive prune + TestFlight 0.12.0 (15); executed 2026-09-05): page:3439
- Latest TestFlight: **0.12.0 (15)** cut 2026-09-05 11:58Z from main `377e848` (P1 `87497ce` IMGMGR-371, P3 `94e9d20` IMGMGR-362, P2 `5814d19` IMGMGR-376/-339, bump `944f714`); ASC read-back VALID / household / IN_BETA_TESTING; dSYMs + provenance on janus `img-manager-ios/dSYMs/0.12.0-15/`. Owner device pass outstanding (IMGMGR-373).
- Design records (WP21): page:3376 (review-done from sibling edits, ADR-0004 Amendment 1), page:3386 (RAW+JPEG capture pairs), page:3396 (tree-grouped folder home, IMGMGR-350), page:3401 (offline folders, IMGMGR-331/-262)
- Product specification: page:3213
