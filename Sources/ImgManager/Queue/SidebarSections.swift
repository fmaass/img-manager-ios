/// IMGMGR-549 (design R3-2): which of the home's sections render, in the record's order —
/// Untouched · Pinned · Recent · Library. Pure, so the order and each toggle are a test.
///
/// A section renders only when its Settings toggle is on AND it has members; the two reasons a
/// section is absent are kept apart (`state(of:…)`), because "the reader hid it" and "nothing is
/// in it" are different facts even though both draw nothing. Library is the home's permanent
/// navigation surface: P9 shipped exactly three toggles, so it has none and always renders.
/// Pinned exists only on the Regular sidebar (ruling c): the Compact Shoots tab shows Untouched
/// above Recent, and the Compact Library tab is the tree alone.
enum SidebarSection: CaseIterable, Equatable, Sendable {
  case untouched
  case pinned
  case recent
  case library
}

/// The three Settings toggles, copied out of `SettingsPreferences` so the rule reads values.
struct SidebarToggles: Equatable, Sendable {
  var showUntouched = true
  var showPinned = true
  var showRecent = true
}

/// How many rows each optional section would list.
struct SidebarMembership: Equatable, Sendable {
  var untouched = 0
  var pinned = 0
  var recent = 0
}

enum SidebarSections {

  enum Presence: Equatable, Sendable {
    case shown
    /// The reader turned the section off in Settings.
    case hidden
    /// The section is on and has no members.
    case empty
  }

  /// Which shell is asking: the Regular sidebar, or the Compact Shoots tab.
  enum Shell: Equatable, Sendable {
    case regularSidebar
    case compactShoots
  }

  static func state(
    of section: SidebarSection, toggles: SidebarToggles, membership: SidebarMembership
  ) -> Presence {
    switch section {
    case .untouched:
      return !toggles.showUntouched ? .hidden : (membership.untouched > 0 ? .shown : .empty)
    case .pinned:
      return !toggles.showPinned ? .hidden : (membership.pinned > 0 ? .shown : .empty)
    case .recent:
      return !toggles.showRecent ? .hidden : (membership.recent > 0 ? .shown : .empty)
    case .library:
      return .shown
    }
  }

  /// The sections that render, top to bottom.
  static func visible(
    toggles: SidebarToggles, membership: SidebarMembership, in shell: Shell = .regularSidebar
  ) -> [SidebarSection] {
    let candidates: [SidebarSection] =
      switch shell {
      case .regularSidebar: SidebarSection.allCases
      case .compactShoots: [.untouched, .recent]
      }
    return candidates.filter {
      state(of: $0, toggles: toggles, membership: membership) == .shown
    }
  }
}

extension SidebarToggles {
  @MainActor init(_ settings: SettingsPreferences) {
    self.init(
      showUntouched: settings.showUntouched, showPinned: settings.showPinned,
      showRecent: settings.showRecent)
  }
}
