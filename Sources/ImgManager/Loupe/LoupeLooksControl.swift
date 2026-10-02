import ImgManagerAPI
import SwiftUI

/// IMGMGR-382: the loupe's Looks control — the first item of the trailing group
/// (`LoupeChromeLayout`). A `Button` that presents a popover, the shape `GridArrangeControl`
/// ships; at Compact the system adapts the popover to a sheet, as it does for Arrange.
///
/// Tinted while a look is active and neutral otherwise, with the same fact in words as its
/// accessibility value: "Off", the look's name, or "<name>, unavailable for this photo" when the
/// photograph in front of the reader is being shown without it. Disabled while the catalogue is
/// empty (not fetched yet, the fetch failed, or the server offers no look).
struct LoupeLooksControl: View {
  let looks: LookModel
  let focusedImageID: Int?
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Label(LoupeChromeItem.looks.title, systemImage: "camera.filters")
    }
    .foregroundStyle(looks.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    .disabled(!looks.canChoose)
    .accessibilityIdentifier(LoupeChromeItem.looks.accessibilityIdentifier)
    .accessibilityValue(looks.accessibilityValue(focusedImageID: focusedImageID))
    .accessibilityAddTraits(looks.isActive ? [.isSelected] : [])
    .popover(isPresented: $isPresented) {
      LooksPopoverView(looks: looks)
    }
  }
}

/// The popover's body: None, then one row per look in the server's order — the name, its
/// category as secondary text, and a checkmark on the active one. Choosing a row dismisses.
///
/// A `ScrollView` over an eager `VStack`, never a `List`, for the reason `ArrangePopoverView`
/// records: a lazy list builds no accessibility element for a row it has not scrolled to.
struct LooksPopoverView: View {
  let looks: LookModel
  @Environment(\.dismiss) private var dismiss

  /// A row's identifier: `loupeLook-none` for None, `loupeLook-<look id>` otherwise.
  nonisolated static func rowIdentifier(for lookID: String?) -> String {
    "loupeLook-\(lookID ?? "none")"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        row(lookID: nil, title: "None", category: nil)
        ForEach(looks.catalogue, id: \.id) { look in
          row(lookID: look.id, title: look.name, category: look.category)
        }
      }
      .padding(.vertical, 8)
    }
    .frame(idealWidth: 280, idealHeight: 360)
  }

  private func row(lookID: String?, title: String, category: String?) -> some View {
    let checked = looks.activeLookID == lookID
    return Button {
      looks.select(lookID)
      dismiss()
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if let category {
            Text(category)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .opacity(checked ? 1 : 0)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(Self.rowIdentifier(for: lookID))
    // The checkmark in words, for VoiceOver and for a UI test that cannot read pixels.
    .accessibilityValue(checked ? "Checked" : "Unchecked")
    .accessibilityAddTraits(checked ? .isSelected : [])
  }
}
