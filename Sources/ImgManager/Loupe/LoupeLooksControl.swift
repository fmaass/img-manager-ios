import ImgManagerAPI
import SwiftUI

/// IMGMGR-382, reshaped by IMGMGR-543: the loupe's Looks control — the first item of the
/// trailing group (`LoupeChromeLayout`). It opens the Looks strip on the focused photograph
/// (`LooksStripView`, in the filmstrip's place), or cancels it when it is open; the popover it
/// used to present is gone (R3-10).
///
/// Tinted while the strip is open or a look is previewed, neutral otherwise, with the same fact
/// in words as its accessibility value: "Off", the look's name, or "<name>, unavailable for this
/// photo". Disabled while the catalogue is empty (not fetched yet, the fetch failed, or the
/// server offers no look).
struct LoupeLooksControl: View {
  let looks: LookModel
  let focusedImageID: Int?
  let toggle: () -> Void

  var body: some View {
    let isOpen = looks.isStripOpen(for: focusedImageID)
    Button(action: toggle) {
      Label(LoupeChromeItem.looks.title, systemImage: "camera.filters")
    }
    .foregroundStyle(isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    .disabled(!looks.canChoose)
    .accessibilityIdentifier(LoupeChromeItem.looks.accessibilityIdentifier)
    .accessibilityValue(looks.accessibilityValue(focusedImageID: focusedImageID))
    .accessibilityAddTraits(isOpen ? [.isSelected] : [])
  }
}
