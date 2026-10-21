import ImgManagerAPI
import SwiftUI

/// IMGMGR-549: what "N more ›" opens — EVERY Untouched member as a grid of folder tiles, in the
/// section's own order, presented as a sheet on both idioms.
///
/// It lists the same membership the section draws its first eight rows from
/// (`Untouched.members(from:since:)`), never a subtree's image grid, which would show touched
/// shoots too. A tile tap does not navigate from inside the sheet: it hands the shoot to
/// `onPick`, and the presenter dismisses the sheet and opens the shoot from its `onDismiss`,
/// through the same routing closure a row tap uses — so the open is recorded once, like a row's
/// (`UntouchedOverflow`, the presenter's state, owns that once).
///
/// The sheet's identifier sits on its title text, a leaf, never on the `NavigationStack`: an
/// identifier on a container can override its descendants' and hide the tiles' own.
struct UntouchedAllView: View {
  let members: [Components.Schemas.FolderSummary]
  let heroLoader: HeroThumbnailLoader
  let onPick: (Components.Schemas.FolderSummary) -> Void
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
          ForEach(members, id: \.folderId) { summary in
            Button {
              onPick(summary)
            } label: {
              UntouchedTile(summary: summary, heroLoader: heroLoader)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(Untouched.tileIdentifier(for: summary.folderId))
          }
        }
        .padding()
      }
      .navigationTitle(Untouched.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text(Untouched.title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(Untouched.allSheetIdentifier)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onClose)
        }
      }
    }
  }
}

/// The presenter's state for the overflow sheet: whether it is up, and the tile picked in it,
/// which is opened once the sheet has gone. `handOff(to:)` is the sheet's `onDismiss` and hands
/// the pick over AT MOST ONCE — a second dismissal callback, or a swipe-down with nothing picked,
/// opens nothing — so one tile selection is one call of the routing closure (and so one call of
/// the open recorder behind it).
struct UntouchedOverflow {
  var isPresented = false
  private(set) var picked: Components.Schemas.FolderSummary?

  /// "N more ›": present the sheet with nothing picked yet.
  mutating func open() {
    picked = nil
    isPresented = true
  }

  /// A tile tap: remember the shoot and dismiss; nothing opens until the sheet has gone.
  mutating func pick(_ summary: Components.Schemas.FolderSummary) {
    picked = summary
    isPresented = false
  }

  /// Done: dismiss with nothing to open.
  mutating func close() {
    picked = nil
    isPresented = false
  }

  /// The sheet's `onDismiss`: open the picked shoot through `open`, then forget it.
  mutating func handOff(to open: (Int, GridSourceTier?) -> Void) {
    guard let shoot = picked else { return }
    picked = nil
    open(shoot.folderId, GridSourceTier(rawValue: shoot.sourceTier))
  }
}

/// One folder tile: the shoot's cover through the shared loader, its name and its day.
private struct UntouchedTile: View {
  let summary: Components.Schemas.FolderSummary
  let heroLoader: HeroThumbnailLoader

  @State private var cover: PlatformImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Color.secondary.opacity(0.15)
        .aspectRatio(4 / 3, contentMode: .fit)
        .overlay {
          if let cover {
            PlatformImageView(image: cover).aspectRatio(contentMode: .fill)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
      HStack(spacing: 4) {
        Text(ShootName.of(summary))
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        UntouchedRing(identifier: "untouchedRing-all-\(summary.folderId)")
      }
      if let day = Untouched.day(of: summary) {
        Text(day, format: Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .task(id: "\(summary.folderId)|\(summary.sourceTier)") {
      switch await heroLoader.hero(
        folderID: summary.folderId, sourceTier: GridSourceTier(rawValue: summary.sourceTier))
      {
      case .image(let data):
        if let decoded = PlatformImage(data: data), !Task.isCancelled {
          cover = decoded
        }
      case .empty, .failure:
        break
      }
    }
  }
}
