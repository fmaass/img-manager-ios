# Release notes

One `## <version> (<build>)` section per build, newest first. `fastlane beta` sends the section
headed with the archived version and build as the build's TestFlight "What to Test" text, and
refuses to upload when that section is missing, empty or duplicated; Settings › About › Version
opens the same notes in the app. Written for the person testing: what changed on screen, one
point per line, no ticket keys and no host names. TestFlight shows them as plain text.

## 0.15.5 (27)

- Scene cards have a chevron in the bottom-right corner that opens the scene's photos in rows right below the card. Several scenes can be open at once. Esc closes the most recently opened one, More › Collapse all closes them all, and closing puts the grid back where it was.
- New Sync to Lightroom sheet, under More › Shoot › Sync to Lightroom… and, on iPad, in the Sync section of the Shoot Summary. Choose This shoot or Whole library, turn on Lightroom is closed, then press Sync now. It writes picks and dislikes to the sidecars; a mark you cleared is removed from the sidecar too.
- The sheet's status line shows how many marks are not yet written to sidecars, the last sync time, how many were refused, and how many sit on JPEG or HEIF files that can't travel. It also says Read Metadata from Files in Lightroom is not confirmed: run that in Lightroom after a sync.
- Settings › Lightroom Sync shows the Mode, On demand. Automatic is listed but off, with the reason: it needs a signal that Lightroom is not writing sidecars, and that signal does not exist yet.

## 0.15.4 (26)

- Arrange can now group by Mark or by Rating. Picks, Dislikes and each star rating get their own header with a count, and one row at the end opens the photos without a mark or without a rating.
- Grouping by Day or Month is gone from Arrange and from the keyboard menu.
- Folder covers now refresh after the server changes how it renders previews. Before, a cover could keep the old rendering until the app was relaunched.

## 0.15.3 (25)

- The sidebar now shows Untouched, Pinned, Recent and Library, in that order. Needs review is gone.
- Untouched lists the newest incoming shoots you have not looked at yet, dated on or after the Untouched Since date in Settings. It shows 8, then "N more ›" opens all of them.
- Long-press a shoot to Pin or Unpin it. Pins and Recent (the last 6 shoots you opened) are kept on this device.
- A hollow ring marks untouched shoots in the sidebar and the folder tree. The tree no longer shows the readiness caption.
- On iPhone, the Shoots tab shows Untouched above Recent, and its badge counts untouched shoots.

## 0.15.2 (24)

- A folder now opens grouped by Scene when it has scenes, and in Flat when it has none.
- When a pick, dislike or clear fails to save, a banner says how many did not save, with Retry and Dismiss. It shows in the grid, the photo view, Compare and Triage.
- Tapping another photo while a mark is still saving now applies after it instead of being dropped. A quick second tap on the same photo is still ignored, so a double tap cannot undo a pick.
- Settings › About › Version opens What's new with these notes.

## 0.15.1 (23)

- Arrange has a new Layout choice before Thumbnail size: Justified, as before, or Square, which shows every photo as an equal square tile. The choice is not saved yet.
- Tapping a scene card now opens the scene as its own screen instead of expanding it inside the grid; Back returns to the shoot.
- A scene card shows how many photos it opens.
- Known gap on iPad: a scene card cannot be reached with the hardware keyboard yet.

## 0.15.0 (22)

- Settings is one sheet now, opened from the account button and, on iPad, from a new gear in the sidebar. Its groups are Account, Sidebar, Library, Lightroom Sync, Culling, Grid Display, Storage and About.
- Sidebar chooses whether Untouched, Pinned and Recent appear above Library, and Library sets the day Untouched starts from.
- Culling adds Start with Tap to Pick: opening a shoot turns Tap to Pick on.
- Lightroom Sync shows its Mode, which cannot be changed yet.
- The grid sits on black, with thinner gaps between tiles at the two smallest thumbnail sizes.
- More › View has a Tile overlays submenu: Marks, Edited, Lightroom rating, Source kind and Filename plates.
- Search is gone: the iPad grid bar has no search field and the iPhone has no Search tab. The filter has a Keyword row instead, listing up to thirty keywords, most used first.
