# Release notes

One `## <version> (<build>)` section per build, newest first. `fastlane beta` sends the section
headed with the archived version and build as the build's TestFlight "What to Test" text, and
refuses to upload when that section is missing, empty or duplicated; Settings › About › Version
opens the same notes in the app. Written for the person testing: what changed on screen, one
point per line, no ticket keys and no host names. TestFlight shows them as plain text.

## 0.16.0 (29)

- In the photo view, the open Looks panel has a new Presets row under the looks. Tap one of your Lightroom presets to see the photo through it once it has rendered; Original and Preset switch between the two. The row says when a render is still on its way, Check Again asks once more when it takes long, and a long-press on a preset that failed says why. A preset the app can only apply approximately is marked as approximate. Share sends the photo through the preset, for example to Files.
- The Presets row opens on your favourite presets when you have any, with All to show every group. Without favourites it shows all groups.
- When a look changed on the server after you previewed it, Apply now saves nothing and asks you to preview the look again. Preview it again, then Apply.
- The line under the photo view's title adds updated after a saved look that has changed on the server since you applied it.
- Pick Lock now stays on when you change Arrange > Group, for example to Scene. It ends only with Done, when you leave the folder, or with Select.

## 0.15.6 (28)

- In the photo view, Looks now opens a strip in the filmstrip's place, each tile showing the photo through one look: None first, then Favourites, Film, Camera, Mono and Other. Long-press a look to add it to Favourites, which are kept on this device. Set the strength under the strip, from 0 to 200 %, then press Apply or Cancel. With a keyboard, ← and → choose a look, ↑ and ↓ change the strength by 10 %, and Esc cancels.
- The line under the photo view's title now shows Lightroom's star rating and colour label after the source, for example Master · ★★★★☆ · ● Red, when the photo's sidecar carries them.
- Apply saves the look on the photo: the grid and the photo view show the photo through it, its tile carries the Looks icon, and the line under the title names the look and its strength. Choose None and Apply to remove it. A Lightroom edit shows instead of the look, and the line says superseded by edit. Filters has a new Look section with Has look, and Share sends the preview through the saved look, or says it couldn't be prepared.
- A pick or dislike that hit a conflict after you moved to another folder or changed the filter now stays in the banner of marks that did not save, so Retry can still deal with it. Before, it could drop out of the count unsaved.
- Choosing None or Scene under Arrange › Group while a folder is still opening now sticks. Before, the folder's own default could switch it back a moment later.
- A folder cover could stay empty while the list of shoots kept refreshing. It now loads.
- Grouped by Mark or Rating, the photo list recovers cleanly when it went out of date while you scrolled, and after a refresh that fails the group headers no longer show counts that don't match the photos below them.

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
