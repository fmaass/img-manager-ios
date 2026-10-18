import SwiftUI

/// The Settings sheet (IMGMGR-548, design p4336 R3-4) — opened from the sidebar gear and from
/// the persistent `person.crop.circle` account item. It replaces the account sheet and keeps its
/// sign-out machinery verbatim: "Sign Out…" is destructive and every tap routes through
/// `SignOutFlow`, so a reflexive second tap can never revoke a live credential without the
/// confirmation dialog actually being answered (p1-spec-rev2.md §3 item 2).
///
/// Groups in the design record's order (`SettingsSection`). Every row's words, identifier and
/// binding come from `SettingsForm.swift`, so the unit tests drive the same getter and setter a
/// `Toggle` here binds to. The quick toggles stay in their menus; a row here writes the SAME
/// object or key the menu does. No offline row and no offline placeholder (p4337 Decision 5).
///
/// It takes `GridPreferences` and `SettingsPreferences` rather than reaching for globals, so the
/// sheet a test builds owns its own suite exactly like every other consumer of those types.
struct SettingsSheetView: View {
  var auth: AuthSession
  var preferences: GridPreferences
  var settings: SettingsPreferences
  /// Whether the Regular-only "Show Sidebar" row is offered (Compact has no sidebar).
  var showsSidebarVisibilityRow: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var stage: SignOutFlow.Stage = .idle
  /// The shared sidebar flag, observed in `settings.defaults` purely so a write another window's
  /// split makes while this sheet is open re-evaluates `body`; the row's VALUE still comes from
  /// `SettingsToggle.isOn` alone.
  @AppStorage private var observedSidebarHidden: Bool

  init(
    auth: AuthSession, preferences: GridPreferences, settings: SettingsPreferences,
    showsSidebarVisibilityRow: Bool = true
  ) {
    self.auth = auth
    self.preferences = preferences
    self.settings = settings
    self.showsSidebarVisibilityRow = showsSidebarVisibilityRow
    _observedSidebarHidden = AppStorage(
      wrappedValue: SidebarVisibilityMemory.hiddenDefault, SidebarVisibilityMemory.hiddenKey,
      store: settings.defaults)
  }

  private var subject: String? {
    if case .signedIn(let subject) = auth.status { return subject }
    return nil
  }

  var body: some View {
    // Read once so `@AppStorage` registers the dependency (see `observedSidebarHidden`).
    let _ = observedSidebarHidden
    NavigationStack {
      List {
        ForEach(SettingsSection.allCases, id: \.self) { section in
          Section {
            rows(for: section)
          } header: {
            Text(section.title)
              .textCase(nil)
              .accessibilityIdentifier(section.headerIdentifier)
          } footer: {
            if let footer = section.footer {
              Text(footer)
            }
          }
        }
      }
      .accessibilityIdentifier("settingsList")
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .confirmationDialog(
      "Sign out of img-manager?",
      isPresented: Binding(
        get: { stage == .asking },
        set: { presented in
          if !presented { stage = SignOutFlow.next(stage, on: .cancelled) }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) { confirmSignOut() }
      Button("Cancel", role: .cancel) { stage = SignOutFlow.next(stage, on: .cancelled) }
    }
    .alert(
      "Sign-out incomplete",
      isPresented: Binding(
        get: {
          if case .explaining = stage { return true }
          return false
        },
        set: { presented in
          if !presented { stage = SignOutFlow.next(stage, on: .cancelled) }
        }
      ),
      presenting: explainingDecision
    ) { decision in
      Button(decision.discardTitle, role: .destructive) {
        Task {
          await auth.forgetDeviceAnyway()
          dismiss()
        }
      }
      Button("Try Again") { confirmSignOut() }
      Button("Cancel", role: .cancel) { stage = SignOutFlow.next(stage, on: .cancelled) }
    } message: { decision in
      Text(decision.message)
    }
  }

  @ViewBuilder
  private func rows(for section: SettingsSection) -> some View {
    switch section {
    case .account:
      Text(subject.map { "Signed in as \($0)" } ?? SettingsStaticRow.signedIn.title)
        .accessibilityIdentifier(SettingsStaticRow.signedIn.identifier)
      LabeledContent(
        SettingsStaticRow.server.title, value: ImgManagerAPIClient.baseURL.host() ?? "—"
      )
      .accessibilityIdentifier(SettingsStaticRow.server.identifier)
      // No identifier: UI tests find it by its title, as they did on the account sheet.
      Button(SettingsStaticRow.signOut.title, role: .destructive) {
        stage = SignOutFlow.next(stage, on: .requested)
      }
    case .library:
      DatePicker(
        SettingsStaticRow.untouchedSince.title,
        selection: Binding(
          get: { UntouchedSince.displayedDate(forStored: settings.untouchedSince) },
          set: { settings.untouchedSince = UntouchedSince.storedDate(forDisplayed: $0) }),
        displayedComponents: .date
      )
      .environment(\.timeZone, UntouchedSince.displayTimeZone)
      .accessibilityIdentifier(SettingsStaticRow.untouchedSince.identifier)
    case .lightroomSync:
      // Inert until P17 builds sync: shown, disabled, nothing stored.
      LabeledContent(
        SettingsStaticRow.lightroomMode.title, value: SettingsStaticRow.lightroomModeValue
      )
      .disabled(true)
      .accessibilityIdentifier(SettingsStaticRow.lightroomMode.identifier)
    case .about:
      LabeledContent(
        SettingsStaticRow.version.title,
        value: SettingsAbout.versionLine(info: Bundle.main.infoDictionary)
      )
      .accessibilityIdentifier(SettingsStaticRow.version.identifier)
    case .sidebar, .culling, .gridDisplay, .storage:
      ForEach(
        SettingsToggle.rows(in: section, showsRegularOnly: showsSidebarVisibilityRow), id: \.self
      ) { toggle in
        toggleRow(toggle)
      }
    }
  }

  @ViewBuilder
  private func toggleRow(_ toggle: SettingsToggle) -> some View {
    Toggle(
      toggle.title,
      isOn: Binding(
        get: { toggle.isOn(grid: preferences, settings: settings) },
        set: { toggle.set($0, grid: preferences, settings: settings) })
    )
    .accessibilityIdentifier(toggle.identifier)
    if let caption = toggle.caption {
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var explainingDecision: SignOutFlow.Decision? {
    guard case .explaining(let decision) = stage else { return nil }
    return decision
  }

  private func confirmSignOut() {
    stage = SignOutFlow.next(stage, on: .confirmed)
    Task {
      let outcome = await auth.signOut()
      stage = SignOutFlow.next(stage, on: .revokeReturned(outcome))
      if outcome != .revokeFailed { dismiss() }
    }
  }
}
