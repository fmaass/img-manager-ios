import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP14 P4's FIRST-ACTION probe, in the shape `StackServiceContractProbeTests` and
/// `DownloadContractProbeTests` established: the EDITING endpoints — the three of WP14 P4 and
/// IMGMGR-347's absorb — exercised through the
/// REAL generated client (`GridService` → `Client` → `Types`/`Operations`) over
/// `GridStubTransport`, so a renamed operation, a moved path or a changed error schema breaks at
/// the call site rather than inside a hand-written model.
///
/// It answers three questions the vendored document alone cannot: that the request bodies reach
/// the wire in the shape the schema declares, that the 409 — the extraction's alone until v0.20.0
/// declared it on merge and split too — decodes to a typed reason, and that the 503's
/// `Retry-After` is reachable from the generated `Output`.
///
/// It is a PROBE, not a regression test for this lane's behaviour — the behaviour lives in
/// `GridStoreSceneEditTests`. The topology derivation fence (a manual stack is never re-joined)
/// stays a BACKEND gate (`tests/test_api_stack_edit.py`); nothing here is claimed as evidence of it.
@Suite("WP14 P4 generated-contract probe — stack edits (FIRST ACTION)")
struct StackEditContractProbeTests {

  private func makeService(_ transport: GridStubTransport) -> GridService {
    GridService(client: ImgManagerAPIClient.make(transport: transport))
  }

  private func result(
    stacks: [Int], dissolved: [Int] = [], loosened: [Int] = []
  ) -> Components.Schemas.StackEditResult {
    Components.Schemas.StackEditResult(
      dissolvedStackIds: dissolved, loosenedImageIds: loosened, stackIds: stacks)
  }

  private func decodedBody(_ record: GridStubTransport.RecordedStackEdit) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: record.body)) as? [String: Any] ?? [:]
  }

  @Test("POST /api/stacks/merge sends `stack_ids` verbatim and decodes the edit result")
  func mergeSendsStackIDsAndDecodesResult() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.success(result(stacks: [5], dissolved: [6])))
    let service = makeService(transport)

    let edit = try await service.mergeStacks(stackIDs: [5, 6])
    #expect(edit.stackIds == [5])
    #expect(edit.dissolvedStackIds == [6])

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/merge"))
    #expect(decodedBody(record)["stack_ids"] as? [Int] == [5, 6])
  }

  @Test("POST /api/stacks/{id}/split carries the id in the PATH and `at_image_id` in the body")
  func splitSendsPathAndAtImageID() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.success(result(stacks: [5, 9])))
    let service = makeService(transport)

    let edit = try await service.splitStack(stackID: 5, atImageID: 42)
    #expect(edit.stackIds == [5, 9])

    let records = await transport.recordedStackEdits
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/split"))
    #expect(decodedBody(record)["at_image_id"] as? Int == 42)
  }

  @Test("POST /api/stacks/{id}/extract sends exactly the named ids, in order")
  func extractSendsTheChosenIDs() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.success(result(stacks: [5, 9])))
    let service = makeService(transport)

    _ = try await service.extractFromStack(stackID: 5, imageIDs: [3, 2])

    let records = await transport.recordedStackEdits
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/extract"))
    // Order preserved: the client sends the membership-ordered intersection, not a set.
    #expect(decodedBody(record)["image_ids"] as? [Int] == [3, 2])
  }

  @Test("POST /api/stacks/{id}/absorb names the TARGET in the path and the loose ids in the body")
  func absorbSendsTargetPathAndImageIDs() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.success(result(stacks: [5])))
    let service = makeService(transport)

    let edit = try await service.absorbIntoStack(stackID: 5, imageIDs: [20])
    #expect(edit.stackIds == [5])
    // An absorb only ADDS members: nothing dissolves and nothing is loosened, which is what the
    // topology coordinator's reopen set is built from.
    #expect(edit.dissolvedStackIds.isEmpty)
    #expect(edit.loosenedImageIds.isEmpty)

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    // The id in the PATH is the scene the photographs JOIN — the one editor whose path id is not
    // the subject the reader was already inside.
    #expect(record.path.hasSuffix("/api/stacks/5/absorb"))
    #expect(decodedBody(record)["image_ids"] as? [Int] == [20])
  }

  /// The absorb is the ONE editor that declares a 404, and it means two different disappearances
  /// (the scene, or a photograph the request named as `unknown_image`). The contract declares NO
  /// content for it, so the generated `Output` carries no body to decode and the coded detail on
  /// the wire cannot change the mapping — which is why this probe sends one anyway.
  @Test("The absorb's 404 is typed as vanished, whatever coded detail rides on it")
  func absorbNotFoundIsVanished() async throws {
    for code in ["unknown_image", "anything_else"] {
      let transport = GridStubTransport()
      await transport.setStackEditOutcome(.vanished(code: code))
      let service = makeService(transport)
      do {
        _ = try await service.absorbIntoStack(stackID: 5, imageIDs: [20])
        Issue.record("expected a refusal for a 404 carrying \(code)")
      } catch StackEditError.vanished {
        // expected
      } catch {
        Issue.record("expected .vanished, got \(error)")
      }
    }
  }

  /// The contract widened `StackExtractConflictError` to this route (IMGMGR-289): both codes mean
  /// the same two things from the other direction — a loose photograph of ANOTHER folder, and one
  /// that stopped being loose between the check and the write.
  @Test("The absorb's 409 decodes to the same TYPED reasons the extraction declares")
  func absorbConflictDecodesBothCodes() async throws {
    for (code, expected) in [
      (
        Components.Schemas.StackExtractConflict.CodePayload.foreignFolderMember,
        SceneEditConflictReason.foreignFolderMember
      ),
      (
        Components.Schemas.StackExtractConflict.CodePayload.membershipChanged,
        SceneEditConflictReason.membershipChanged
      ),
    ] {
      let transport = GridStubTransport()
      await transport.setStackEditOutcome(.conflict(code))
      let service = makeService(transport)
      do {
        _ = try await service.absorbIntoStack(stackID: 5, imageIDs: [20])
        Issue.record("expected a conflict for \(code)")
      } catch StackEditError.conflict(let reason) {
        #expect(reason == expected)
      } catch {
        Issue.record("expected .conflict, got \(error)")
      }
    }
  }

  /// The recorded position this route carried is CLOSED (IMGMGR-371). `not_loose` and
  /// `tombstoned_image` still go on the wire as an OBJECT detail, but img-manager v0.20.0 declares
  /// that object (`StackEditRefusalError`) instead of FastAPI's array-shaped `HTTPValidationError`,
  /// so the generated client decodes it and the refusal arrives as `.refused` rather than as the
  /// `.unreachable` an undecodable body produced. The SERVER declared the coded object, which is
  /// exactly what the old position said the fix had to be — no hand-written client model.
  @Test("The absorb's coded 422 is a refusal — both codes this route can emit")
  func absorbCodedRefusalIsARefusal() async throws {
    for code in ["not_loose", "tombstoned_image"] {
      let transport = GridStubTransport()
      await transport.setStackEditOutcome(.refusedCodedDetail(code: code))
      do {
        _ = try await makeService(transport).absorbIntoStack(stackID: 5, imageIDs: [20])
        Issue.record("expected a refusal for \(code)")
      } catch StackEditError.refused {
        // expected: the declared coded body decoded through the generated boundary.
      } catch {
        Issue.record("expected .refused for a coded 422 carrying \(code), got \(error)")
      }
    }
  }

  @Test("The extraction's 409 decodes to its TYPED reason — both declared codes")
  func extractConflictDecodesBothCodes() async throws {
    for (code, expected) in [
      (
        Components.Schemas.StackExtractConflict.CodePayload.foreignFolderMember,
        SceneEditConflictReason.foreignFolderMember
      ),
      (
        Components.Schemas.StackExtractConflict.CodePayload.membershipChanged,
        SceneEditConflictReason.membershipChanged
      ),
    ] {
      let transport = GridStubTransport()
      await transport.setStackEditOutcome(.conflict(code))
      let service = makeService(transport)
      do {
        _ = try await service.extractFromStack(stackID: 5, imageIDs: [2])
        Issue.record("expected a conflict for \(code)")
      } catch StackEditError.conflict(let reason) {
        #expect(reason == expected)
      } catch {
        Issue.record("expected .conflict, got \(error)")
      }
    }
  }

  /// The recut widened `StackExtractConflictError` to the merge and the split (IMGMGR-371), which
  /// makes their generated `Output` carry a `.conflict` case it did not have — a route gaining a
  /// response code is a compile-time event here, and this is the test that says what the new arm
  /// must answer. Both codes on both routes: the mapping is the extraction's, mirrored, so a
  /// divergence between the four editors' 409 handling fails here rather than in a reader's alert.
  @Test("The merge's and the split's NEW 409 decode to the same typed reasons")
  func mergeAndSplitConflictDecodeBothCodes() async throws {
    for (code, expected) in [
      (
        Components.Schemas.StackExtractConflict.CodePayload.foreignFolderMember,
        SceneEditConflictReason.foreignFolderMember
      ),
      (
        Components.Schemas.StackExtractConflict.CodePayload.membershipChanged,
        SceneEditConflictReason.membershipChanged
      ),
    ] {
      let merge = GridStubTransport()
      await merge.setStackEditOutcome(.conflict(code))
      do {
        _ = try await makeService(merge).mergeStacks(stackIDs: [5, 6])
        Issue.record("expected a merge conflict for \(code)")
      } catch StackEditError.conflict(let reason) {
        #expect(reason == expected)
      } catch {
        Issue.record("expected .conflict on the merge, got \(error)")
      }

      let split = GridStubTransport()
      await split.setStackEditOutcome(.conflict(code))
      do {
        _ = try await makeService(split).splitStack(stackID: 5, atImageID: 2)
        Issue.record("expected a split conflict for \(code)")
      } catch StackEditError.conflict(let reason) {
        #expect(reason == expected)
      } catch {
        Issue.record("expected .conflict on the split, got \(error)")
      }
    }
  }

  @Test("The 503 is typed as busy and carries the Retry-After the server named")
  func busyCarriesRetryAfter() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.busy(retryAfterSeconds: 7))
    let service = makeService(transport)
    do {
      _ = try await service.splitStack(stackID: 5, atImageID: 2)
      Issue.record("expected a busy refusal")
    } catch StackEditError.busy(let seconds) {
      #expect(seconds == 7)
    } catch {
      Issue.record("expected .busy, got \(error)")
    }
  }

  @Test("A 503 with no Retry-After is still busy — the header is optional in the contract")
  func busyWithoutRetryAfter() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.busy(retryAfterSeconds: nil))
    let service = makeService(transport)
    do {
      _ = try await service.mergeStacks(stackIDs: [5, 6])
      Issue.record("expected a busy refusal")
    } catch StackEditError.busy(let seconds) {
      #expect(seconds == nil)
    } catch {
      Issue.record("expected .busy, got \(error)")
    }
  }

  @Test("A 422 in the DECLARED shape is a refusal, never a reachability failure")
  func declaredValidationErrorIsARefusal() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.refused)
    let service = makeService(transport)
    do {
      _ = try await service.splitStack(stackID: 5, atImageID: 2)
      Issue.record("expected a refusal")
    } catch StackEditError.refused {
      // expected
    } catch {
      Issue.record("expected .refused, got \(error)")
    }
  }

  /// THE POSITION THIS SUITE RECORDED (WP14 P4), NOW CLOSED (IMGMGR-371). The editing routes used
  /// to declare FastAPI's default `HTTPValidationError` for 422 — `detail` an ARRAY — while the
  /// coded refusals (`empty_split_side`, `not_a_member`, `cross_folder_merge`) went on the wire as
  /// an OBJECT detail the schema documented in PROSE only. The generated client decodes a declared
  /// response body EAGERLY, so that body did not decode at all and the refusal reached this app as
  /// `.unreachable`. That same eagerness is what makes this test the flip's evidence: img-manager
  /// v0.20.0 declares `StackEditRefusalError` on all six editors, so arriving in
  /// `.unprocessableContent` at all is proof the coded body decoded through the generated
  /// boundary — the mapping does not re-read it.
  ///
  /// The client still cannot construct these refusals by design (the merge target list is filtered
  /// to the subject's own folder, a split at the first member is disabled, and an extraction that
  /// would empty the scene is disabled) — but the answer it would give is now the contract's own.
  @Test("A coded-object 422 decodes through the declared schema and is a refusal")
  func codedObjectValidationErrorArrivesAsRefused() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.refusedCodedDetail(code: "empty_split_side"))
    let service = makeService(transport)
    do {
      _ = try await service.splitStack(stackID: 5, atImageID: 2)
      Issue.record("expected a refusal of some kind")
    } catch StackEditError.refused {
      // expected
    } catch {
      Issue.record("expected .refused for a coded-object 422, got \(error)")
    }
  }

  /// The two codes the recut BROUGHT INTO the coded declaration rather than found there
  /// (`StackEditRefusal`'s own docstring): a merge of fewer than two distinct scenes was a plain
  /// string, and a malformed body was FastAPI's `HTTPValidationError` mapped by a route-scoped
  /// handler. They are pinned on the two routes that emit them — merge and, for the malformed
  /// body, an editor that takes one — so the four mapped editors are covered between them and the
  /// two tests above.
  @Test("`too_few_stacks` on the merge and `invalid_request` on the extraction are refusals")
  func recutAddedCodesAreRefusals() async throws {
    let merge = GridStubTransport()
    await merge.setStackEditOutcome(.refusedCodedDetail(code: "too_few_stacks"))
    do {
      _ = try await makeService(merge).mergeStacks(stackIDs: [5, 5])
      Issue.record("expected a refusal for too_few_stacks")
    } catch StackEditError.refused {
      // expected
    } catch {
      Issue.record("expected .refused for too_few_stacks, got \(error)")
    }

    let extract = GridStubTransport()
    await extract.setStackEditOutcome(.refusedCodedDetail(code: "invalid_request"))
    do {
      _ = try await makeService(extract).extractFromStack(stackID: 5, imageIDs: [2])
      Issue.record("expected a refusal for invalid_request")
    } catch StackEditError.refused {
      // expected
    } catch {
      Issue.record("expected .refused for invalid_request, got \(error)")
    }
  }

  @Test("A transport that cannot reach the server is `.unreachable`, never a refusal")
  func transportFailureIsUnreachable() async throws {
    // No case is configured for this operation on the auth-only stub, so the transport throws —
    // the network-level failure `GridService` maps to `.unreachable`.
    let service = GridService(
      client: ImgManagerAPIClient.make(transport: AuthOperationStubTransport()))
    do {
      _ = try await service.mergeStacks(stackIDs: [5, 6])
      Issue.record("expected .unreachable")
    } catch StackEditError.unreachable {
      // expected
    } catch {
      Issue.record("expected .unreachable, got \(error)")
    }
  }
}

/// IMGMGR-371's second contract probe, kept beside the stack-edit one because the recut that
/// declared the coded 422 declared this envelope in the same breath and both are proven the same
/// way — through the REAL generated client over `GridStubTransport`, never a hand-written model.
///
/// `CountCancelledError` is declared 503 on `GET /api/facets`, `GET /api/image-groups` and
/// `GET /api/images/selection`. This client calls the first two and makes no selection-count call
/// at all, so there are two decodes to pin and no third promised. The Postgres cancel behind it
/// (SQLSTATE 57014) is the server's own business; what matters here is that a cancelled count is
/// neither a reachability failure nor a count of zero, and that the `Retry-After` beside it
/// survives the generated boundary.
@Suite("WP21 P1 contract-recut probe — the 503 count_cancelled envelope")
struct CountCancelledContractProbeTests {

  private func makeService(_ transport: GridStubTransport) -> GridService {
    GridService(client: ImgManagerAPIClient.make(transport: transport))
  }

  @Test("GET /api/facets: a cancelled count is typed, and carries the Retry-After it named")
  func facetsCountCancelledIsTypedWithRetryAfter() async throws {
    let transport = GridStubTransport()
    await transport.setFacetsCountCancelled(.init(retryAfterSeconds: 11))
    do {
      _ = try await makeService(transport).facets(GridImagesQuery())
      Issue.record("expected a cancelled count")
    } catch GridServiceError.countCancelled(let seconds) {
      #expect(seconds == 11)
    } catch {
      Issue.record("expected .countCancelled, got \(error)")
    }
  }

  @Test("GET /api/image-groups: the same envelope, and no Retry-After is still a cancelled count")
  func imageGroupsCountCancelledSurvivesAMissingHeader() async throws {
    let transport = GridStubTransport()
    await transport.setImageGroupsCountCancelled(.init(retryAfterSeconds: nil))
    do {
      _ = try await makeService(transport).imageGroups(GridImagesQuery(folderID: 1), groupBy: .day)
      Issue.record("expected a cancelled count")
    } catch GridServiceError.countCancelled(let seconds) {
      #expect(seconds == nil)
    } catch {
      Issue.record("expected .countCancelled, got \(error)")
    }
  }
}
