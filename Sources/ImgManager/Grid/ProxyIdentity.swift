import Foundation

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
