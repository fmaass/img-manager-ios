import Foundation

/// IMGMGR-548: `library.untouchedSince` — STORED as 00:00:00 UTC of a calendar day, DISPLAYED in
/// Europe/Zurich. Pure, so the day arithmetic is unit-tested at the DST and year boundaries
/// (`SettingsPreferencesTests`). P10 compares a folder's date against the stored UTC midnight.
enum UntouchedSince {
  /// Europe/Zurich; GMT only if the system lacks the zone (a unit test pins that it does not).
  static let displayTimeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt

  static func calendar(in zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }

  /// The picker's date → the stored value: the Zurich calendar day of `displayed`, at 00:00 UTC.
  static func storedDate(forDisplayed displayed: Date, zone: TimeZone = displayTimeZone) -> Date {
    let day = calendar(in: zone).dateComponents([.year, .month, .day], from: displayed)
    return utcMidnight(year: day.year, month: day.month, day: day.day) ?? displayed
  }

  /// The stored value → the picker's date: the UTC calendar day of `stored`, at NOON in Zurich,
  /// so no DST edge can move the picker to a neighbouring day.
  static func displayedDate(forStored stored: Date, zone: TimeZone = displayTimeZone) -> Date {
    let day = calendar(in: .gmt).dateComponents([.year, .month, .day], from: stored)
    var noon = DateComponents()
    noon.year = day.year
    noon.month = day.month
    noon.day = day.day
    noon.hour = 12
    return calendar(in: zone).date(from: noon) ?? stored
  }

  /// 1 January of `now`'s year in Zurich, at 00:00 UTC (design p4336 R3-2's default).
  static func defaultStored(now: Date, zone: TimeZone = displayTimeZone) -> Date {
    let year = calendar(in: zone).component(.year, from: now)
    return utcMidnight(year: year, month: 1, day: 1) ?? now
  }

  private static func utcMidnight(year: Int?, month: Int?, day: Int?) -> Date? {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return calendar(in: .gmt).date(from: components)
  }
}
