import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime
import Testing

@testable import ImgManager

/// IMGMGR-544 (plan §1.9): the DEBUG stub's saved looks belong to the transport actor and are
/// written to standard `UserDefaults` on every PUT/DELETE, so a NEW transport — the next
/// process in `LookPersistenceUITests` — reads back what the previous one saved.
@Suite("DEBUG stub — saved looks persist across transports", .serialized)
struct DebugStubLookPersistenceTests {

  #if DEBUG
    private let base = URL(string: "https://example.invalid")!

    @Test("a PUT is read back by a new transport: summaries carry it and has_look filters by it")
    func aPutSurvivesANewTransport() async throws {
      forget()
      defer { forget() }
      #expect(try await images(DebugStubTransport(), query: "?has_look=true").isEmpty)

      let (status, view) = try await put(DebugStubTransport(), imageID: 2, lookID: "warm-film")
      #expect(status == .ok)
      #expect(view?.lookId == "warm-film")
      #expect(view?.strength == 120)

      let next = DebugStubTransport()
      let all = try await images(next, query: "")
      #expect(all.first { $0.id == 2 }?.look?.lookId == "warm-film")
      #expect(all.first { $0.id == 2 }?.look?.strength == 120)
      #expect(all.filter { $0.look != nil }.map(\.id) == [2])
      #expect(try await images(next, query: "?has_look=true").map(\.id) == [2])
      #expect(try await images(next, query: "?has_look=false").count == all.count - 1)
    }

    @Test("an unknown look is the catalogue's 422 and saves nothing")
    func anUnknownLookIsRefused() async throws {
      forget()
      defer { forget() }
      let (status, _) = try await put(DebugStubTransport(), imageID: 2, lookID: "no-such-look")
      #expect(status == .unprocessableContent)
      #expect(try await images(DebugStubTransport(), query: "?has_look=true").isEmpty)
    }

    @Test("a DELETE is 204 and a new transport no longer sees the look")
    func aDeleteForgets() async throws {
      forget()
      defer { forget() }
      let transport = DebugStubTransport()
      _ = try await put(transport, imageID: 3, lookID: "cool-matte")
      let request = HTTPRequest(
        method: .delete, scheme: nil, authority: nil, path: "/api/images/3/look")
      let (response, _) = try await transport.send(
        request, body: nil, baseURL: base,
        operationID: Operations.DeleteImageLookApiImagesImageIdLookDelete.id)
      #expect(response.status == .noContent)
      #expect(try await images(DebugStubTransport(), query: "?has_look=true").isEmpty)
    }

    @Test("two PUTs racing on one transport are both kept")
    func racingPutsAreBothKept() async throws {
      forget()
      defer { forget() }
      let transport = DebugStubTransport()
      async let first = put(transport, imageID: 2, lookID: "warm-film")
      async let second = put(transport, imageID: 5, lookID: "classic-mono")
      _ = try await (first, second)
      let saved = try await images(DebugStubTransport(), query: "?has_look=true")
      #expect(Set(saved.map(\.id)) == [2, 5])
    }

    @Test("the looked 200 carries X-Look-Version: md5(look|strength|tier), 32 lower-case hex")
    func theLookedProxyCarriesItsVersion() async throws {
      let grid = try await lookedVersion(tier: "grid")
      let preview = try await lookedVersion(tier: "preview")
      #expect(
        grid == DebugStubTransport.lookVersion(lookID: "warm-film", strength: 120, tier: "grid"))
      #expect(LookedCache.isVersion(grid))
      #expect(grid != preview)
    }

    @Test("outside a fixture launch the reset leaves the key alone")
    func theResetIsFixtureOnly() throws {
      let suite = "DebugStubLookPersistenceTests.reset"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(Data("{}".utf8), forKey: DebugStubTransport.savedLooksKey)
      DebugStubLaunch.resetSavedLooksUnlessKept(defaults: defaults)
      #expect(!DebugStubLaunch.isActive)
      #expect(defaults.data(forKey: DebugStubTransport.savedLooksKey) != nil)
    }

    private func forget() {
      UserDefaults.standard.removeObject(forKey: DebugStubTransport.savedLooksKey)
    }

    private func put(_ transport: DebugStubTransport, imageID: Int, lookID: String) async throws
      -> (HTTPResponse.Status, Components.Schemas.ImageLookView?)
    {
      let request = HTTPRequest(
        method: .put, scheme: nil, authority: nil, path: "/api/images/\(imageID)/look")
      let json = #"{"look_id": "\#(lookID)", "strength": 120}"#
      let (response, body) = try await transport.send(
        request, body: HTTPBody(Data(json.utf8)), baseURL: base,
        operationID: Operations.PutImageLookApiImagesImageIdLookPut.id)
      guard response.status == .ok, let body else { return (response.status, nil) }
      let data = try await Data(collecting: body, upTo: 1_000_000)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let view = try decoder.decode(Components.Schemas.ImageLookView.self, from: data)
      return (response.status, view)
    }

    private func images(_ transport: DebugStubTransport, query: String) async throws
      -> [Components.Schemas.ImageSummary]
    {
      let request = HTTPRequest(
        method: .get, scheme: nil, authority: nil, path: "/api/images\(query)")
      let (_, body) = try await transport.send(
        request, body: nil, baseURL: base, operationID: Operations.ListImagesApiImagesGet.id)
      let data = try await Data(collecting: try #require(body), upTo: 1_000_000)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(Components.Schemas.ImagePage.self, from: data).items
    }

    private func lookedVersion(tier: String) async throws -> String? {
      let request = HTTPRequest(
        method: .get, scheme: nil, authority: nil,
        path: "/api/images/2/proxy/\(tier)/look/warm-film?strength=120")
      let (response, _) = try await DebugStubTransport().send(
        request, body: nil, baseURL: base,
        operationID: Operations.GetLookedProxyApiImagesImageIdProxyTierLookLookIdGet.id)
      return HTTPField.Name("X-Look-Version").flatMap { response.headerFields[$0] }
    }
  #endif
}
