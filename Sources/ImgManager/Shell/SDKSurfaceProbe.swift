#if DEBUG
  import SwiftUI

  /// WP28 P1 (IMGMGR-448): the SDK probe. A view nothing ever instantiates, compiled only so the
  /// gate's build leg answers whether every iOS 26 surface the WP28 plan names is spelled the way
  /// the plan spells it on the Mac's SDK (26.5) — before any shipped view depends on one. A
  /// missing symbol here is a build failure that names the API, which is the evidence the plan's
  /// fallback rule asks for; it is never worked around inside this file.
  ///
  /// System components only (ADR-N1): nothing here draws glass of its own. The
  /// `.backgroundExtensionEffect()` call is a SPELLING check and nothing more — WP28 holds that
  /// modifier out of every shipped view until the owner rules on ADR-N1's clear-variant clause.
  struct SDKSurfaceProbe: View {
    @State private var tab = SDKSurfaceProbeTab.titled
    @State private var query = ""
    @State private var showsInspector = false
    @State private var showsSheet = false

    var body: some View {
      TabView(selection: $tab) {
        Tab("Titled", systemImage: "square", value: SDKSurfaceProbeTab.titled) {
          stack
        }
        .badge(2)
        Tab(value: SDKSurfaceProbeTab.labelled) {
          Text("Labelled")
        } label: {
          Label("Labelled", systemImage: "circle")
            .accessibilityIdentifier("probe.labelled")
        }
        Tab(value: SDKSurfaceProbeTab.search, role: .search) {
          NavigationStack { Text("Search") }
        }
        Tab(value: SDKSurfaceProbeTab.labelledSearch, role: .search) {
          Text("Labelled search")
        } label: {
          Label("Search", systemImage: "magnifyingglass")
        }
      }
      .searchable(text: $query)
      .tabBarMinimizeBehavior(.onScrollDown)
    }

    private var stack: some View {
      NavigationStack {
        Text("Probe")
          .backgroundExtensionEffect()
          .navigationTitle("Probe")
          .toolbarTitleMenu {
            Button("Row") {}
          }
          .toolbar {
            ToolbarItem(placement: .primaryAction) {
              Button("First") {}
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
              Button("Second") {}
            }
          }
          .searchable(text: $query)
          .searchToolbarBehavior(.minimize)
          .inspector(isPresented: $showsInspector) {
            Text("Inspector")
              .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
          }
          .sheet(isPresented: $showsSheet) {
            Text("Sheet")
              .presentationDetents([.medium, .large])
              .presentationSizing(.form)
          }
      }
    }
  }

  private enum SDKSurfaceProbeTab: Hashable {
    case titled
    case labelled
    case search
    case labelledSearch
  }
#endif
