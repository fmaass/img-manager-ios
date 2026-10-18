**BLOCKING findings**

1. **The P-key test does not exercise the required focused-card condition.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:132-143` substitutes “nothing is focused after Back” for “P on a focused card.” That proves cleanup, not the card’s actionability boundary. Establish keyboard/UI focus on the card or its opening control without assigning its representative to `focusedImageID`, dispatch P, and assert no transport request. Include a positive control proving that the same key-dispatch path marks an actual member. M3 is also insufficiently justified: retaining a hidden member’s focus should still produce no request if the actionable-image fence works.  
   The push test at `:125-128` exercises only the handle; add coverage of the required **card-body tap**, including with the latch engaged.

2. **The proposed single source of truth still has an independently mutable membership state.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:43-51,75-85,170-171` retains `sceneExpanded`, depends on its observation, and proposes direct `enteredSceneID = nil` assignments at query boundaries. Existing scene-edit subject resolution reads `sceneExpanded`, not `enteredSceneID` (`Sources/ImgManager/Grid/GridStore.swift:1797-1801`). The plan needs an enforced invariant—preferably a derived expansion set—or a single transition function covering every reset. Otherwise display/actionability can leave the scene while edit-subject state still names it, and direct resets can bypass the promised focus/selection/loupe cleanup.

3. **Topology reload and navigation synchronization need explicit transition rules.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:76-84` proposes capturing the scene, calling `reloadFirstPage()`, then re-entering the result, while also resetting entered state at a reload site. Explain precisely which reloads clear the scene and which preserve it throughout the asynchronous operation; otherwise the nil transition can trigger the unwanted Compact pop identified at `:178`.

   Likewise, “idempotent guards, no loop” at `:50-51` does not establish which event wins during host replacement or layout changes. Existing `showSelectedShoot` replaces the path with `[.workspace]` (`Sources/ImgManager/Shell/WorkspaceNavigation.swift:56-62`). A programmatic path rebuild must not be interpreted as the user leaving the scene. Add reconciliation tests covering system Back/swipe, host replacement, both layout transitions, and topology reload—not only tests of navigation methods (`plan:152`).

4. **The inactive-grid write boundary is incomplete.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:53-61,111` gates rows, scroll anchors, and paging, but `:172-173` itself identifies shared pointer-drag tile frames as another racing writer without specifying its fix. Make frame publication and cleanup scope-owned too: an outgoing view must neither overwrite nor clear the active view’s frames. Audit other shared interaction writes and specify how pending paging work behaves when ownership changes. Verify with both Compact grid instances alive; store-only entry/exit tests cannot establish this property.

5. **Absence from a refreshed page is not evidence that the entered scene disappeared.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:83-84` leaves the scene when the refreshed page lacks its stack. A valid scene opened from a later browse page can be absent from that page. Preserve entry unless an authoritative lookup or topology result establishes removal; the existing stack-row reread mentioned at `:119` is a possible seam. Add a regression test that opens a scene beyond the first page and refreshes without leaving it.

**ADVISORY findings**

- **C2–C7:** C2 is reasonable given the explicitly unfiltered member query, provided Filter **and every Arrange query-change path** use the same cleanup transition and preserve the chosen settings/latch (`plan:32,80-85,191-193`). C3 conflicts with Compact retaining its existing scroll position “by construction”; choose and test one Compact return behavior (`:57-61,194-195`). C4’s flag removal is appropriate. C5’s no-push absorb behavior is defensible, but is an intentional behavior change requiring replacement assertions. C6 and C7 are reasonable deferrals; the supplied requirements do not demand keyboard Back or relaunch restoration.

- **Make the transport probe an independent request log.** At `plan:119,125-133,176-177`, distinguish append-only request recording from fixture mark state. Record each outgoing mark request independently of whether it changes state; assert the successful request targets member 601. Derive fixture counts from seeded per-image state and actual transitions, so repeated picks do not inflate counts. Verify both the stack reread and subsequent member reads agree. The transport implementation is not inlined, so its correctness cannot yet be assessed.

- **Specify loading, failure, and retry presentation for the pushed scene.** `Sources/ImgManager/Grid/SceneRows.swift:129-133` explicitly preserves a visible control during initial loading or empty membership. The new member-only projection (`plan:63-64`) removes that fallback, and `:87-89` removes the old progress indicator. Define the replacement, including Back while loading and retry after failure.

- **Existing-test preservation needs assertion mapping.** `plan:156-164` lists affected tests but does not establish that their guarantees survive. A toggle-to-enter rename is not mechanical for tests that call the method twice. Map collapse assertions to explicit leave, preserve actionability/selection/filmstrip/refresh checks, and replace multi-band assumptions with active-scene isolation checks. Keep absorb outcomes and counts covered even when intentionally changing navigation.

- **Make Swift conformance requirements explicit.** `GridScope` needs `Hashable` for `.id(...)` and equality checks, in addition to the planned `Sendable` conformance (`plan:54-59,174-175`). Keep reconciliation actor-isolated and route destination branching within a suitable view builder. These are implementation obligations, not demonstrated compiler failures.

- **Preserve the settled visual and actionability decisions.** C1’s sanctioned material capsule, bottom-edge verdict counts, and removal of expanded-card styling match R3-8. Keeping `.stack` without an image ID preserves the core ADR-0005 boundary (`Sources/ImgManager/Grid/SceneRows.swift:17-25`). Member long-press editing is consistent with that boundary; card long-press need not become a write target. Also verify the folder-named Back requirement with long folder titles rather than assuming the system always displays the full previous title (`plan:45-47`).

VERDICT: REVISE
