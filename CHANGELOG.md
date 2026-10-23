# Changelog

Notable changes to PhotoVault, newest first. Versions follow
MAJOR.MINOR.PATCH: a patch fixes something, a minor version adds something, a
major version changes how vaults are stored.

## [Unreleased]

## [1.8.0] — 2026-10-23

- **A user manual** in the app: Help › PhotoVault User Manual (⌘?). Nine
  chapters, from getting started to troubleshooting, in a window of its own
  with a search, and a Keyboard Shortcuts chapter (Help › Keyboard
  Shortcuts, ⌘/).
- Fixed: a PhotoVault that macOS runs from a temporary copy now says so, with
  the fix, instead of saying it can't find its catalog.
- The vault's README: copy a password-protected vault in Finder; a copy made
  with hdiutil has no password.
- The installer zip carries one plain time per file, in UTC.

## [1.7.0] — 2026-10-21

- **Move photos into folders**: drag them from the grid onto a folder in the
  sidebar, or use Move to Folder (with New Folder…). The files move on the
  disk, instantly, keeping their favorites, albums and tags; a name already in
  the folder is never overwritten. Edit › Undo Move puts them back.
- **Drag photos onto an album** to add them to it.
- **A folder shows everything beneath it**, subfolders included, and the
  count at the top is the view's, not the whole vault's.
- **When a file can't be deleted or moved**, PhotoVault says why and offers
  ways through — unlock it, use an administrator's password, show it in
  Finder — instead of an error.
- **Vault › Fix Permissions…** clears what stops photos being moved or
  deleted, such as the rules Time Machine leaves on files restored from a
  backup.
- **Photo tagging is optional** in the installer: untick it to leave JoyTag
  out and save about 370 MB.

## [1.6.0] — 2026-10-17

- **Scroll automatically**: Play in the grid's toolbar (or Space) scrolls an
  album, folder or All Media slowly by itself, at a speed you choose.
- **Keyboard shortcuts**, shown in the menus, right-click menus and tooltips,
  and all listed in Help › Keyboard Shortcuts (⌘?). New ones for new albums,
  the All / Photos / Videos filter, thumbnail size, Show Whole Photos (⌘0),
  sort direction, Repeat and Play Next. The full stop (.) adds to Favorites
  anywhere; the arrow keys move through the grid's photos; Shift on its own
  opens the photo picked, and goes back again.
- **PhotoVault opens where you left it**: the same view, filter and place,
  with the photo that was open. Each view keeps its own All, Photos or Videos.
- **R18 tags hidden** in a photo's details and the smart album filter unless
  Image › Classifier › Show R18 Tags is ticked. Only the tags: photos and smart
  albums are unaffected.
- **Random in the viewer** gives way to the Random sort order, which Play Next
  follows.
- Fixed: renaming, moving or deleting a folder made its photos look new —
  thumbnailed and tagged again, with their favorites and albums left behind
  on the old entries. They're now followed to their new place, and a vault
  this happened to is repaired when it next opens.
- Fixed: Esc didn't leave a playing video; the arrow keys skipped through a
  video instead of moving to the next item; changing the sort moved the grid.

## [1.5.0] — 2026-10-15

- **Sorting**: by video length and at random too, either way round; albums can
  be sorted, with the order photos were added as their default.
- **Each view opens where you left it** — every album, smart album and folder,
  All Media, Favorites and the Trash — even after quitting.
- **Albums**: drag them into the order you want, duplicate them, pick several
  to delete at once, and make a new one straight from Add to Album.
- **Bigger thumbnails**, and View › Show Whole Photos to see each photo
  uncropped.
- **The viewer**: Repeat, Random and Play Next, slideshows with a chosen time
  per photo, one playback speed for every video, and pinch to zoom a video.
- **Password-protected vaults**, from the installer.
- Quicker switching between views, and a quicker tag search in smart albums.
- Fixed: a grey bar over the photo viewer in a window.

## [1.4.0] — 2026-10-14

The first public release.

- **PhotoVault Installer** makes a new vault, or puts PhotoVault on one you
  have, with JoyTag in every vault.
- **Automatic tags from JoyTag**, kept in the vault's catalog; photos are
  never rewritten. Smart albums from tag rules.
- **Sorting** by date taken, date created or file name, either way round, in
  All Media and every folder. Each smart album remembers its own.
- Albums, favorites, folders, a viewer with the photo's details, rotation that
  changes only the orientation, a Trash with Put Back.
- Nothing written outside the vault, and no network use.
