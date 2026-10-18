import Foundation
import ImgManagerAPI

/// `ProxyState.url` is server-built as `/api/images/{id}/proxy/{tier}?v={identity}`
/// (`app/derivatives/availability.py:proxy_url`) — the identity token the proxy operation's own
/// `v` query parameter wants is embedded in that convenience URL string rather than being a
/// separate field on `ImageSummary`/`ImageDetail`. This extracts it so the request still goes
/// through the GENERATED operation (`GridService.proxy`, `Operations.
/// GetProxyApiImagesImageIdProxyTierGet`) with its own typed path/query — never a hand-written
/// client hitting `url` directly (P0a Do-NOT invariant: no hand-written API client method).
enum ProxyIdentity {
  static func token(from urlString: String?) -> String? {
    guard let urlString, let components = URLComponents(string: urlString) else { return nil }
    return components.queryItems?.first(where: { $0.name == "v" })?.value
  }
}

/// R3-15 (IMGMGR-539): what one fetched proxy's bytes ARE, for the in-memory cache and for a
/// tile's load task. The server token (`v`) alone is not enough on the client: a row adopted
/// from a 400-px to an 800-px grid file must reload even if the token a caller holds is the same
/// or nil, so the dimensions the row reported are part of the identity. Only the token is ever
/// SENT (`GridService.proxy`'s `v`); the dimensions stay local.
///
/// Callers that know no dimensions (the loupe, scene chrome, Compare) build it with both nil,
/// which is exactly the token-only key the cache used before.
struct ProxyLocalIdentity: Hashable, Sendable {
  var imageID: Int
  var tier: ProxyTier
  var token: String?
  var width: Int? = nil
  var height: Int? = nil

  /// The identity of `image`'s proxy at `tier` as the loaded `ProxyState` reports it: the token
  /// from its `url`, and its `width`/`height`.
  static func make(image: Components.Schemas.ImageSummary, tier: ProxyTier) -> ProxyLocalIdentity {
    let state = image.proxies.additionalProperties[tier.rawValue]
    return ProxyLocalIdentity(
      imageID: image.id, tier: tier, token: ProxyIdentity.token(from: state?.url),
      width: state?.width, height: state?.height)
  }
}

/// A grid tile's load-task key IS the local proxy identity (one definition): the task restarts
/// when the token or the dimensions change, not only when the image or the tier does.
typealias TileLoadKey = ProxyLocalIdentity
