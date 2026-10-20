import Foundation
import ImgManagerAPI
import Testing

/// IMGMGR-538: the two REQUIRED nullable model references of img-manager 22726ee's sync routes —
/// `SyncRequestOut.report` and `FolderSyncStatusOut.latest` — survive generation as Optional
/// model types.
///
/// The server declares both as `anyOf: [$ref, null]` and lists them in `required`;
/// swift-openapi-generator drops that shape, so `scripts/sync-openapi.sh` rewrites each to the bare
/// `$ref` and takes it out of `required` (response-only schemas only — see
/// `docs/OPENAPI_NORMALIZATION_DEBT.md`, addendum 2026-10-20). That this file compiles at all
/// proves the properties exist as `SyncReportOut?` / `SyncRequestOut?`; the three literals each
/// pin what the relaxed key presence means on the wire: populated, an explicit null, and an absent
/// key — the last decodes as nil where the server promises the key with a null.
///
/// Literals carry every other required field of the vendored schemas, with their exact enum
/// values (`state`, `requested_via`, `states`) and RFC 3339 `date-time` strings.
@Suite("Sync contract — required nullable model references decode as Optional")
struct SyncContractDecodingTests {

  /// `date-time` fields are RFC 3339 on the wire; `.iso8601` reads the second-precision literals.
  private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// `SyncRequestOut` with every required field except `report`, which `reportField` supplies
  /// (`nil` leaves the key out entirely).
  private func syncRequestJSON(reportField: String?) -> String {
    let report = reportField.map { ", \"report\": \($0)" } ?? ""
    return """
      {"id": 41, "folder_id": 7, "states": ["pick", "dislike", "none"], "state": "succeeded",
       "lightroom_closed_confirmed": true, "requested_by": "owner", "requested_via": "bearer",
       "requested_at": "2026-10-20T12:00:00Z", "started_at": "2026-10-20T12:00:05Z",
       "finished_at": null, "run_id": null\(report)}
      """
  }

  private func folderSyncStatusJSON(latestField: String?) -> String {
    let latest = latestField.map { ", \"latest\": \($0)" } ?? ""
    return """
      {"folder_id": 7, "counts": {"synced": 3, "stale": 1, "refused": 0, "never": 2},
       "cannot_travel": 0\(latest)}
      """
  }

  private func decodeRequest(_ json: String) throws -> Components.Schemas.SyncRequestOut {
    try decoder().decode(Components.Schemas.SyncRequestOut.self, from: Data(json.utf8))
  }

  private func decodeStatus(_ json: String) throws -> Components.Schemas.FolderSyncStatusOut {
    try decoder().decode(Components.Schemas.FolderSyncStatusOut.self, from: Data(json.utf8))
  }

  private let populatedReport = #"{"targets": 5, "marks_examined": 12, "counts": {"pick": 4}}"#

  @Test("SyncRequestOut.report: populated decodes the model")
  func reportPopulated() throws {
    let request = try decodeRequest(syncRequestJSON(reportField: populatedReport))
    let report = try #require(request.report)
    #expect(report.targets == 5)
  }

  @Test("SyncRequestOut.report: an explicit null decodes as nil")
  func reportExplicitNull() throws {
    let request = try decodeRequest(syncRequestJSON(reportField: "null"))
    #expect(request.report == nil)
    #expect(request.id == 41)
  }

  @Test("SyncRequestOut.report: an absent key decodes as nil")
  func reportKeyAbsent() throws {
    let request = try decodeRequest(syncRequestJSON(reportField: nil))
    #expect(request.report == nil)
    #expect(request.id == 41)
  }

  @Test("FolderSyncStatusOut.latest: populated decodes the model")
  func latestPopulated() throws {
    let status = try decodeStatus(
      folderSyncStatusJSON(latestField: syncRequestJSON(reportField: populatedReport)))
    let latest = try #require(status.latest)
    #expect(latest.id == 41)
    #expect(latest.report?.targets == 5)
  }

  @Test("FolderSyncStatusOut.latest: an explicit null decodes as nil")
  func latestExplicitNull() throws {
    let status = try decodeStatus(folderSyncStatusJSON(latestField: "null"))
    #expect(status.latest == nil)
    #expect(status.folderId == 7)
  }

  @Test("FolderSyncStatusOut.latest: an absent key decodes as nil")
  func latestKeyAbsent() throws {
    let status = try decodeStatus(folderSyncStatusJSON(latestField: nil))
    #expect(status.latest == nil)
    #expect(status.folderId == 7)
  }
}
