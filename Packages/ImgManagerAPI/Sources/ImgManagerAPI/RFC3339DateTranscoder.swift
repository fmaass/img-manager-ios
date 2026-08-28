import Foundation
import OpenAPIRuntime

/// Reads `date-time` the way RFC 3339 defines it: fractional seconds optional.
///
/// The backend serialises BOTH shapes from the same models — a timestamp whose
/// microseconds happen to be zero comes out as `2026-08-28T09:01:52Z`, every other
/// one as `2027-08-28T07:01:52.019478Z` — and swift-openapi-runtime's default
/// transcoder accepts only the second-precision form. With the default, the very
/// first live token exchange returned 200 and then failed to DECODE, which the
/// sign-in screen could only report as "couldn't reach your server"
/// (live incident 2026-08-28, TestFlight 0.3.0 (3); same trap memos-ng hit).
public struct RFC3339DateTranscoder: DateTranscoder {
  public init() {}

  public func encode(_ date: Date) throws -> String {
    date.formatted(.iso8601.dateTimeSeparator(.standard).timeSeparator(.colon))
  }

  public func decode(_ dateString: String) throws -> Date {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      .parse(dateString)
    {
      return date
    }
    if let date = try? Date.ISO8601FormatStyle().parse(dateString) {
      return date
    }
    throw DecodingError.dataCorrupted(
      .init(
        codingPath: [],
        debugDescription: "Expected an RFC 3339 date-time, got '\(dateString)'"
      )
    )
  }
}
