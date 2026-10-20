# Release notes

One `## <version> (<build>)` section per build, newest first. `fastlane beta` sends the section
headed with the archived version and build as the build's TestFlight "What to Test" text, and
refuses to upload when that section is missing, empty or duplicated; Settings › About › Version
opens the same notes in the app. Written for the person testing: what changed on screen, one
point per line, no ticket keys and no host names. TestFlight shows them as plain text.

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
