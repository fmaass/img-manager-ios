**BLOCKING findings**

1. **Topology completion does not load the scene it retargets to, and can empty a newer scene.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:171` says reload clears the member cache. At `:211`, topology reload disables revalidation and completes members only for the result stack entered **now**. Retargeting at `:216` then changes the entry without fetching its members; `transitionScene` has no fetch (`:84`).

   This breaks two concrete cases:
   - Merge 5 into survivor 6: 5 is currently entered, so 6 is not completed. Retargeting to 6 leaves it without members or an in-flight fetch.
   - Split 5 into [5, 9], with the anchor in 9: completing only 5 cannot establish the anchor’s membership in 9, so the fallback can incorrectly retain 5. T11 requires the opposite.

   Likewise, if the user enters unrelated scene 7 during the edit, the revision check correctly prevents navigation, but the reload clears 7’s members and the prescribed completion path never restores them.

   Determine and load the candidate destination before committing an owned retarget, with ownership checked again after awaits. Independently restore/revalidate whichever scene is currently entered when ownership has changed. Extend the held-edit tests to assert displayed membership, not just `enteredSceneID`.

2. **The prescribed `.stream` rendering removes the Flat grid.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:237` maps `.stream` directly to `store.sceneDisplayRows`. However, `.stream` also applies whenever no scene is entered, including Flat mode (`:230`). The existing store deliberately separates `images` from `sceneRows`, and Flat actionability uses `images` (`Sources/ImgManager/Grid/GridStore.swift:137`, `:201`).

   Preserve the existing display-mode branch within `.stream`: Flat renders `images`; Scene mode renders cards and loose photographs. Add a view-level regression covering Flat rendering and Scene→Flat switching.

**ADVISORY findings**

- **The three round-2 blockers have explicit remedies at plan level.** Separate anchor slots address B1; the edit-owner revision addresses B2’s navigation race; the focus bridge and loose-photo→card request-log test address B3 (`docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:15`). The topology blocker above concerns member loading, independently of that corrected navigation ownership.

- **T8 cannot demonstrate its claimed M46 failure.** At `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:447`, Cancel dismisses the picker before Back. Its flag is already false, so removing transition-time dismissal need not make it reappear. Add a deterministic transition test starting with presentation flags true, and require M46 to fail that assertion.

- **The remaining choices and safeguards are reasonable.** C2 and C4–C7 fit the stated scope; C3’s separate anchors address restoration; C1/C8 follow the rulings (`docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:592`). Member-only actionability, count placement, filmstrip scoping, and member editing match the supplied requirements. The append-only request log and T3’s positive controls provide meaningful mark evidence (`:399`, `:442`). SwiftUI extraction boundaries and Swift 6 conformances are sensible, although implementation must still establish compilation and actual Compact replacement behavior. The existing-test mapping generally preserves assertions; the intentional absorb/navigation changes are identified explicitly (`:507`).

VERDICT: REVISE
