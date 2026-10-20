import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP13 P5b (IMGMGR-221 part 2): the offered sort/group subset against the SERVER's own
/// vocabulary — the vendored contract as the generated client expresses it, never a second
/// hand-written copy of `app/api/sort_keys.py`.
@Suite("Sort/group offered subset (WP13 P5b)")
struct SortGroupOptionsTests {

  @Test("Every offered key is in the server vocabulary — and a known-invalid key is rejected")
  func everyOfferedKeyIsInTheServerVocabulary() {
    // NEGATIVE control FIRST, in the same test: without it, a predicate that answered `true`
    // for everything would make every assertion below pass vacuously. These three strings are
    // not in the server's fifteen sort keys / eleven group keys (live-verified 2026-08-30).
    #expect(!SortGroupOptions.serverAcceptsSortKey("exposure_kelvin"))
    #expect(!SortGroupOptions.serverAcceptsGroupByKey("photographer"))
    #expect(!SortGroupOptions.serverAcceptsDirection("sideways"))
    #expect(!SortGroupOptions.neighboursAcceptSortKey("exposure_kelvin"))
    #expect(!SortGroupOptions.neighboursAcceptGroupByKey("photographer"))
    #expect(!SortGroupOptions.imageGroupsAcceptGroupByKey("photographer"))

    for key in SortGroupOptions.sortKeys {
      #expect(
        SortGroupOptions.serverAcceptsSortKey(key.rawValue),
        "\(key.rawValue) is not a /api/images sort key")
      // The loupe asks the SAME question of the SAME order, so its vocabulary is checked too —
      // the divergence guard below rests on these two being the same set.
      #expect(
        SortGroupOptions.neighboursAcceptSortKey(key.rawValue),
        "\(key.rawValue) is not a neighbours sort key")
    }

    for direction in SortGroupOptions.directions {
      #expect(SortGroupOptions.serverAcceptsDirection(direction.rawValue))
    }

    for key in SortGroupOptions.groupKeys {
      #expect(
        SortGroupOptions.serverAcceptsGroupByKey(key.rawValue),
        "\(key.rawValue) is not a /api/images group_by key")
      #expect(
        SortGroupOptions.neighboursAcceptGroupByKey(key.rawValue),
        "\(key.rawValue) is not a neighbours group_by key")
      #expect(
        SortGroupOptions.imageGroupsAcceptGroupByKey(key.rawValue),
        "\(key.rawValue) is not an /api/image-groups group_by key")
    }
  }

  @Test("Every offered value ROUND-TRIPS through the generated payload it is sent as")
  func everyOfferedValueRoundTripsThroughItsGeneratedPayload() {
    // A typed mapping that returned the wrong case would still be "in the vocabulary" above.
    // This asserts the mapping itself: the payload each value is actually put on the wire as
    // carries that value's own raw string back.
    for key in SortGroupOptions.sortKeys {
      #expect(key.listImagesPayload.rawValue == key.rawValue)
      #expect(key.neighboursPayload.rawValue == key.rawValue)
    }
    for key in SortGroupOptions.groupKeys {
      #expect(key.listImagesPayload.rawValue == key.rawValue)
      #expect(key.neighboursPayload.rawValue == key.rawValue)
      #expect(key.imageGroupsPayload.rawValue == key.rawValue)
    }
  }

  @Test("The offered subset is a PROPER subset, and the omissions are the pinned ones")
  func theOfferedSubsetIsTheDecidedSix() {
    // Pinned so the known-unknown ("is it the right six?") is a one-line change here plus this
    // assertion, never a structural rework — the plan's own pre-decided pivot.
    let offeredSort = SortGroupOptions.sortKeys.map(\.rawValue)
    let offeredGroup = SortGroupOptions.groupKeys.map(\.rawValue)
    #expect(offeredSort == ["date_taken", "filename", "rating", "iso", "camera", "lens"])
    #expect(offeredGroup == ["day", "month", "camera", "lens", "iso", "location"])
    // `hour`, `week` and `year` are the server's other three group keys: too fine and too
    // coarse for a shoot-scoped grid. They must be in the SERVER's vocabulary (proving the
    // subset is proper, not the whole set) and NOT in the offered one.
    for omitted in ["hour", "week", "year"] {
      #expect(SortGroupOptions.serverAcceptsGroupByKey(omitted))
      #expect(!offeredGroup.contains(omitted))
    }
    for omitted in ["file_size", "label", "focal_length", "aperture", "shutter", "mp"] {
      #expect(SortGroupOptions.serverAcceptsSortKey(omitted))
      #expect(!offeredSort.contains(omitted))
    }
  }

  @Test("Grouping is ONE single-select list — Scene and a group_by key cannot both be chosen")
  func groupingIsOneSingleSelectList() {
    let choices = SortGroupOptions.groupingChoices
    // Fully qualified on purpose: bare `.none` against an `Optional<GroupingChoice>` resolves
    // to `Optional.none` — i.e. "is nil" — which is a different assertion that happens to
    // compile (gate run 03:47, `Expectation failed: (choices.first → .none) == (.none → nil)`).
    #expect(choices.first == GroupingChoice.none)
    #expect(choices.dropFirst().first == GroupingChoice.scene)
    #expect(choices.count == 2 + SortGroupOptions.groupKeys.count)
    // Structural exclusivity: `.scene` carries no `group_by` value at all, so choosing it can
    // never also set one, and a `.key` choice is not `.scene`.
    #expect(GroupingChoice.scene.groupByKey == nil)
    #expect(GroupingChoice.none.groupByKey == nil)
    #expect(GroupingChoice.key(.camera).groupByKey == .camera)
    #expect(Set(choices).count == choices.count)
  }

  @Test("Only the TIME keys claim a timezone — the others' responses carry none")
  func onlyTimeKeysClaimATimezone() {
    // Live-probed 2026-08-30: `group_by=day` answered `timezone: "Europe/Zurich"`, `camera` and
    // `location` answered null. Estate ADR-0007: a rendered local time names its zone.
    #expect(GroupByKey.day.isTimeKey)
    #expect(GroupByKey.month.isTimeKey)
    #expect(!GroupByKey.camera.isTimeKey)
    #expect(!GroupByKey.lens.isTimeKey)
    #expect(!GroupByKey.iso.isTimeKey)
    #expect(!GroupByKey.location.isTimeKey)
  }
}
