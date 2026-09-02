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
/// the wire in the shape the schema declares, that the 409 the extraction ALONE declares decodes
/// to a typed reason, and that the 503's `Retry-After` is reachable from the generated `Output`.
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

  /// The absorb inherits the position recorded below for its siblings, and this is where it is
  /// pinned for THIS route: `not_loose` and `tombstoned_image` go on the wire as an OBJECT detail
  /// while the operation declares FastAPI's array-shaped `HTTPValidationError`, so the body does
  /// not decode and the refusal reaches this app as `.unreachable`. Both answers tell the reader
  /// the same true thing — nothing was changed — and closing the gap needs the SERVER to declare
  /// the coded object, not a hand-written client model of it.
  @Test("The absorb's coded 422 arrives as unreachable, and its declared 422 as a refusal")
  func absorbValidationErrorShapes() async throws {
    let coded = GridStubTransport()
    await coded.setStackEditOutcome(.refusedCodedDetail(code: "not_loose"))
    do {
      _ = try await makeService(coded).absorbIntoStack(stackID: 5, imageIDs: [20])
      Issue.record("expected a refusal of some kind")
    } catch StackEditError.unreachable {
      // The recorded position.
    } catch {
      Issue.record("expected .unreachable for a coded-object 422, got \(error)")
    }

    let declared = GridStubTransport()
    await declared.setStackEditOutcome(.refused)
    do {
      _ = try await makeService(declared).absorbIntoStack(stackID: 5, imageIDs: [20])
      Issue.record("expected a refusal")
    } catch StackEditError.refused {
      // expected
    } catch {
      Issue.record("expected .refused, got \(error)")
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

  /// THE POSITION THIS SUITE RECORDS (WP14 P4). The editing routes declare FastAPI's default
  /// `HTTPValidationError` for 422 — `detail` is an ARRAY — while the coded refusals
  /// (`empty_split_side`, `not_a_member`, `cross_folder_merge`) go on the wire as an OBJECT
  /// detail, which the schema documents in PROSE only. The generated client decodes a declared
  /// response body eagerly, so such a body does not decode at all and the refusal reaches this app
  /// as `.unreachable` rather than as `.refused`.
  ///
  /// Recorded rather than worked around: both answers tell the reader nothing was changed, and
  /// this client cannot construct either refusal by design (the merge target list is filtered to
  /// the subject's own folder, a split at the first member is disabled, and an extraction that
  /// would empty the scene is disabled). If the contract ever declares the coded object, this test
  /// is where the change lands.
  @Test("A coded-object 422 does not decode through the declared array schema — recorded")
  func codedObjectValidationErrorArrivesAsUnreachable() async throws {
    let transport = GridStubTransport()
    await transport.setStackEditOutcome(.refusedCodedDetail(code: "empty_split_side"))
    let service = makeService(transport)
    do {
      _ = try await service.splitStack(stackID: 5, atImageID: 2)
      Issue.record("expected a refusal of some kind")
    } catch StackEditError.unreachable {
      // The recorded position.
    } catch {
      Issue.record("expected .unreachable for a coded-object 422, got \(error)")
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
