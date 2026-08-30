import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

@Suite("Inspector model (P4 Approach: Info/Stats separation, no path row, absence-tolerant)")
struct InspectorModelTests {

  private func exif(_ pairs: [String: (String?, Int?, Double?)])
    -> Components.Schemas.ImageDetail
    .ExifPayload
  {
    var props: [String: Components.Schemas.ImageDetail.ExifPayload.AdditionalPropertiesPayload] =
      [:]
    for (key, value) in pairs {
      props[key] = .init(value1: value.0, value2: value.1, value3: value.2)
    }
    return .init(additionalProperties: props)
  }

  @Test("Present EXIF fields render their real value, by whichever union slot is populated")
  func presentFieldsRenderRealValues() {
    let e = exif([
      "Make": ("Fujifilm", nil, nil),
      "ISO": (nil, 400, nil),
      "FNumber": (nil, nil, 2.8),
    ])
    #expect(InspectorExifRow.stringValue(e, key: "Make") == "Fujifilm")
    #expect(InspectorExifRow.stringValue(e, key: "ISO") == "400")
    #expect(InspectorExifRow.stringValue(e, key: "FNumber") == "2.8")
  }

  @Test(
    "A key absent from THIS photograph's exif renders the absence marker, never a crash or a zero")
  func absentKeyRendersAbsenceMarker() {
    let e = exif(["Make": ("Fujifilm", nil, nil)])
    #expect(InspectorExifRow.stringValue(e, key: "LensModel") == InspectorFormat.absent)
    #expect(InspectorExifRow.stringValue(e, key: "LensModel") != "0")
  }

  @Test(
    "A nil exif dictionary entirely still renders every whitelisted row as absent, never throws")
  func nilExifStillRendersAllRowsAbsent() {
    let rows = InspectorExifRow.whitelistedRows(from: nil)
    #expect(rows.count == InspectorExifRow.whitelist.count)
    #expect(rows.allSatisfy { $0.value == InspectorFormat.absent })
  }

  @Test("The whitelist mirrors the web's own field set — same facts, same photograph")
  func whitelistMatchesWebFieldSet() {
    let keys = Set(InspectorExifRow.whitelist.map(\.key))
    #expect(
      keys == [
        "Make", "Model", "LensModel", "ISO", "FNumber", "ExposureTime", "FocalLength",
        "Orientation", "DateTimeOriginal",
      ])
  }

  @Test("Dimensions come from the whitelisted ImageWidth/ImageHeight EXIF keys, absence-tolerant")
  func dimensionsFromExifWidthHeight() {
    let present = exif(["ImageWidth": (nil, 6000, nil), "ImageHeight": (nil, 4000, nil)])
    #expect(InspectorDimensions.label(exif: present) == "6000 × 4000")

    let missing = exif(["ImageWidth": (nil, 6000, nil)])  // no height
    #expect(InspectorDimensions.label(exif: missing) == InspectorFormat.absent)

    #expect(InspectorDimensions.label(exif: nil) == InspectorFormat.absent)
  }

  @Test("My marks and Lightroom are STRUCTURALLY separate types — never merged into one block")
  func markAndLightroomAreSeparateTypes() {
    let mark = Components.Schemas.MarkView(revision: "r1", state: .pick, tags: ["favorite"])
    let lightroom = Components.Schemas.LightroomMeta(
      good: true, keywords: ["wedding"], label: "Red", rating: 4, sidecarPresent: true)

    let markBlock = InspectorMarkBlock.build(from: mark)
    let lightroomBlock = InspectorLightroomBlock.build(from: lightroom)

    #expect(markBlock.stateLabel == "Picked")
    #expect(markBlock.tags == ["favorite"])
    #expect(lightroomBlock.rating == 4)
    #expect(lightroomBlock.label == "Red")
    #expect(lightroomBlock.good == true)
    #expect(lightroomBlock.sidecarPresent == true)

    // Structural: the two are DIFFERENT Swift types with no shared storage — there is no
    // single struct here a merge could have collapsed them into.
    #expect(String(describing: type(of: markBlock)) != String(describing: type(of: lightroomBlock)))
  }

  @Test("No Lightroom sidecar renders as absence, not an empty/zeroed rating")
  func noSidecarIsAbsenceNotZero() {
    let lightroom = Components.Schemas.LightroomMeta(sidecarPresent: false)
    let block = InspectorLightroomBlock.build(from: lightroom)
    #expect(block.sidecarPresent == false)
    #expect(block.rating == nil)
  }

  @Test("No mark state (nil) renders as 'No mark', never a crash")
  func nilMarkStateRendersNoMark() {
    let mark = Components.Schemas.MarkView(revision: "r1", state: nil, tags: nil)
    let block = InspectorMarkBlock.build(from: mark)
    #expect(block.stateLabel == "No mark")
    #expect(block.tags.isEmpty)
  }

  @Test("InspectorInfo has NO property a path could bind to — structural 'no path row'")
  func noPathRowIsStructural() {
    // Reflect the actual field list of the built value and assert none of the labels even
    // suggest a filesystem path — the stronger guarantee is that `InspectorInfo`'s own
    // declaration (source of truth) simply has no such property to reflect in the first
    // place; this mirrors that fact at runtime over a real instance.
    let detail = Components.Schemas.ImageDetail(
      ext: "jpg", fileSize: 4_096, filename: "a.jpg", folderId: 1, id: 1,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r1"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
    let info = InspectorInfo.build(from: detail)
    let mirror = Mirror(reflecting: info)
    let labels = mirror.children.compactMap(\.label)
    #expect(!labels.contains { $0.lowercased().contains("path") })
  }
}
