**BLOCKING findings**

1. **The active scene can overwrite the supposedly frozen stream anchor.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:178-179` accepts anchor writes whenever the caller matches `activeScope`. Inside a scene, that accepts the scene’s writes to the shared `gridScrollAnchor`, contradicting the frozen-at-push guarantee at `:208-213`. Active ownership alone does not preserve separate scroll positions.

   Keep a stream-specific anchor, or store anchors per scope. Scene restoration must also avoid consuming the stream anchor. Add a deterministic test that scrolls inside the scene, then verifies Back restores the original stream position. **R1 B4/C3 remains unresolved here.**

2. **Topology completion can undo a newer Back or scene change.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:141` prescribes retargeting after the entire asynchronous reload, without checking whether the user has since left or changed scenes. The entry fence at `:158-160` belongs to revalidation, which topology reload explicitly disables. A Back during the held reload can therefore be followed by `.retarget`, pushing the scene again. The unconditional rule also needs reconciliation with C5’s no-push stream absorb behavior at `:463`.

   Capture whether the edit owns an entered scene and a navigation-intent revision; retarget only while that ownership remains current. Preserve authoritative data updates independently. Test Back, leaving and re-entering, and a folder-row tap during a held topology operation, plus absorb initiated from the stream. **R1 B3 is only partially resolved.**

3. **Real card focus remains independent of the mark target.**  
   `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:271-279` adds actual card focus but specifies no synchronization with `focusedImageID`. After focusing a loose photograph, moving keyboard focus onto a card can leave that photograph as the store’s mark target. It remains actionable, so neither fence at `:266-269` prevents P from sending a request.

   The test at `:326` starts with `focusedImageID=none`, so it misses this divergence. Define card-focus acquisition and shortcut targeting explicitly, then test **loose-photo focus → actual card focus → P → unchanged request log**, retaining the positive control. The card-body tests resolve that portion of **R1 B1**, but the focused-card guarantee remains incomplete.

**ADVISORY findings**

- **B2 and B5 are concretely addressed.** The computed expansion set and sole transition writer remove independently mutable membership (`docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:53-86`). Authoritative rereading, card splicing, and U14 correctly distinguish first-page absence from removal (`:146-166`, `:352`). The pure navigation projection also removes the original two-way synchronization loop.

- **Specify presentation binding setters, not only masked getters.**  
  `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:187-192` defines `isActive && flag`, but not how dismissal writes are handled. An outgoing instance’s dismissal must not clear a presentation owned by the active instance. Include that handover in T8.

- **Keep framework behavior separate from pure-function proof.**  
  `docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:109-110` assumes every binding write represents user navigation. R9’s pure projection test cannot establish SwiftUI’s behavior during destination replacement. Add a Compact topology-retarget integration test verifying the displayed destination and store entry remain aligned. The planned conformances and view-builder boundaries otherwise address the identified Swift/type-check concerns.

- **Finish the failure-state and pending-work specifications.**  
  A stack-row lookup failure must explicitly populate the state consumed by `SceneScreenState`; currently the failure set is described as updated only by the member-fetch catch (`docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:155-157`, `:226-235`). Also explain how transition-time removal of queued crossings at `:70` preserves the “pruned while waiting is reported” assertion promised at `:391`.

- **The request-log redesign is sound at plan level; tighten mutation evidence.**  
  Append-only request recording and independently derived fixture state address the earlier concern (`docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:283-295`). However, M18 at `:326` is undefined. Specify it and require the focused-card mutant to fail on the request-log assertion after satisfying the focus precondition. The existing-test assertion mapping is substantially improved; implementation must preserve those mapped guarantees.

- **Choices and visual scope:** C1 and C8 follow the rulings. C2 and C4–C7 are reasonable; C3 needs blocking finding 1 resolved. The count capsule, bottom-edge verdict counts, member-only actionability, scene filmstrip, and member long-press editing match the supplied requirements (`docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md:218-262`).

VERDICT: REVISE
