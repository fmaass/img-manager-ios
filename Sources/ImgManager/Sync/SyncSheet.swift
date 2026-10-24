import SwiftUI

/// IMGMGR-545: the Sync sheet, raised from More › Shoot. The form itself is `SyncSheetContent`,
/// which the Summary's sync block pushes inside its own navigation stack instead.
struct SyncSheet: View {
  let service: SyncService
  let folderID: Int?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      SyncSheetContent(service: service, folderID: folderID)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
              .accessibilityIdentifier("syncSheetDone")
          }
        }
    }
  }
}

/// The Sync form: status lines, target, the per-request confirmation, Sync now, and the watched
/// request. It owns ONE model for as long as it is shown; showing it again builds a new one.
struct SyncSheetContent: View {
  @State private var model: SyncSheetModel

  init(service: SyncService, folderID: Int?) {
    _model = State(initialValue: SyncSheetModel(service: service, folderID: folderID))
  }

  var body: some View {
    Form {
      Section {
        Text(model.statusLine)
          .accessibilityIdentifier("syncStatusLine")
        Text(SyncCopy.readMetadataLine)
          .accessibilityIdentifier("syncReadMetadataLine")
      }
      Section {
        Picker(SyncCopy.targetTitle, selection: $model.target) {
          ForEach(model.targets, id: \.self) { target in
            Text(SyncCopy.targetName(target)).tag(target)
          }
        }
        .disabled(model.isTargetLocked)
        .accessibilityIdentifier("syncTargetPicker")
        VStack(alignment: .leading, spacing: 4) {
          LabeledContent(SyncCopy.contentTitle, value: SyncCopy.contentValue)
          Text(SyncCopy.contentCaption)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("syncContentRow")
      }
      Section {
        Toggle(SyncCopy.lightroomClosedLabel, isOn: $model.lightroomClosed)
          .disabled(model.isSubmitting)
          .accessibilityIdentifier("syncLightroomClosedSwitch")
        Button(SyncCopy.syncNowTitle) { model.syncNow() }
          .disabled(!model.canSyncNow)
          .accessibilityIdentifier("syncNowButton")
      } footer: {
        Text(SyncCopy.switchFooter)
      }
      if model.notice != nil || model.stateLine != nil {
        Section {
          if let notice = model.notice {
            Text(notice)
              .accessibilityIdentifier("syncNotice")
          }
          if let line = model.stateLine {
            Text(line)
              .accessibilityIdentifier("syncRequestStateLine")
          }
        }
      }
    }
    .navigationTitle(SyncCopy.title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.start() }
    .task(id: model.watched?.request.id) { await model.poll() }
    .onDisappear { model.cancel() }
  }
}

/// R3-14: the Summary sheet's sync block (Regular layouts only, `SyncPlacement`). Its own
/// status read, and a push to a fresh Sync form inside the Summary's navigation stack — never
/// a nested sheet.
struct SyncSummaryBlock: View {
  /// Owned and started by `ShootSummarySheet`, on the sheet's own lifecycle.
  let model: SyncSheetModel
  let service: SyncService
  let folderID: Int

  var body: some View {
    Section(SyncCopy.title) {
      Text(model.statusLine)
        .accessibilityIdentifier("shootSummary.syncStatusLine")
      NavigationLink(SyncCopy.summaryLinkTitle) {
        SyncSheetContent(service: service, folderID: folderID)
      }
      .accessibilityIdentifier("shootSummary.syncLink")
    }
  }
}
