# PhotoVault

A photo library that lives entirely inside one portable disk image.

A vault is a macOS sparse bundle holding your photos and videos, the
PhotoVault app, and its catalog of albums, favorites and tags. Copy the bundle
to another Mac or an external drive and everything comes with it. PhotoVault
writes nothing outside the vault: no preferences, caches, thumbnails or saved
window state in your home folder, and it never connects to the internet.

## Features

- **Browse** every photo and video in the vault, or folder by folder — a
  folder shows everything in it and its subfolders — sorted by date taken,
  date created, file name, video length or at random, either way round. Every
  view opens where you left it, and PhotoVault opens on the view you were last
  in. The grid can scroll by itself at a speed you choose.
- **Organize the files themselves**: drag photos onto a folder in the sidebar
  to move them there (instantly, keeping their favorites, albums and tags), or
  onto an album to add them. Undo Move puts them back.
- **Albums, favorites and smart albums.** Smart albums pick their photos from
  tag rules: include or exclude tags, match any or all. Drag albums into the
  order you want, duplicate them, and sort each one its own way.
- **Automatic tags from [JoyTag](https://github.com/fpgaminer/joytag)**, which
  names what's in a picture (5,813 tags) and runs on your Mac, from the
  thumbnails PhotoVault already keeps. Tags are kept in the vault's catalog:
  your photos are never rewritten. Tags are grouped under everyday names in an
  editable text file in the vault (`.Tag Groups.txt`).
- **A viewer** with zoom for photos and videos, the photo's details (file,
  dates, dimensions, the keywords already in it, its tags) and video playback
  — with Repeat and Play Next, slideshows, and one playback speed for
  every video.
- **Keyboard shortcuts** for nearly everything, shown beside each command and
  listed in Help › Keyboard Shortcuts.
- **A user manual** in the app: Help › PhotoVault User Manual (⌘?).
- **Rotate JPEGs** without re-encoding: only the orientation value changes, so
  every other byte, and the photo's dates, stay as they were.
- **Trash** with Put Back. Files leave the disk only when you empty it. When
  macOS won't let a file be deleted or moved, PhotoVault says why and offers
  ways through; **Vault › Fix Permissions…** clears what stops them, such as
  the rules Time Machine leaves on files restored from a backup.
- **Eject** from inside the app (⌘E), which is the order macOS needs: the app
  runs from the vault, so the vault can't eject while it's open.

## Requirements

- A Mac with Apple silicon, running macOS 14 or later.
- Automatic tagging needs macOS 15 or later. On macOS 14, PhotoVault works
  without it.

## Install

1. Download `PhotoVault-Installer-<version>.zip` from
   [Releases](../../releases) and open it.
2. Open **PhotoVault Installer**. The first time, macOS may say it can't check
   it for malicious software: open **System Settings › Privacy & Security** and
   click **Open Anyway**. (The app is not notarized by Apple.)
3. Choose one:
   - **Create a New Vault** — a new disk image, with PhotoVault, JoyTag and an
     empty Photos folder. Choose its name, where to save it, and the most it
     can hold (it only takes the space its photos use). It can be protected
     with a password: then nobody can open it without one — and a forgotten
     password can't be recovered. Untick **Include photo tagging** to leave
     JoyTag out and save about 370 MB; PhotoVault then doesn't tag photos.
   - **Install on an Existing Vault** — puts this version of PhotoVault on a
     vault you have. Its photos, albums and tags stay as they are.

Then copy your photos and videos into the vault's **Photos** folder and open
PhotoVault from the vault. It finds the photos, makes their thumbnails, and
tags them.

To update later, open a newer installer and choose **Install on an Existing
Vault**.

## Using a plain folder instead of a disk image

PhotoVault also works in an ordinary folder: put `PhotoVault.app` in a folder
beside a folder called `Photos`, holding your photos and videos, and open it.
PhotoVault makes its catalog (a hidden `.catalog` folder) beside them, and
the installer's **Install on an Existing Vault** accepts such a folder too.

This way is **mostly untested**. Everything is meant to work as it does on a
disk image, but it hasn't had the same use. Some things differ by nature: the
folder is only as portable and private as wherever it lives, there's no
password, and **Eject** ejects the whole drive the folder is on, if it's an
external one. Keep a copy of your photos elsewhere while you try it.

## Keeping photos on the vault

PhotoVault never copies a decoded image off the vault, and its own tests check
that. One habit can, though: browsing the vault's Photos folder in Finder's
icon or gallery view. Finder asks Quick Look for thumbnails, and Quick Look
keeps them in a shared cache in your home folder. List and column views don't.

## Building from source

Needs Xcode (Swift 6) on macOS. Everything is in this repository; there are no
package dependencies.

```bash
Scripts/test.sh            # unit tests
Scripts/check.sh           # unit tests, then the app end to end on a throwaway vault
Scripts/build-app.sh       # builds build/PhotoVault.app
```

JoyTag's model isn't in the repository. It's downloaded from its published
source, pinned to fixed versions, converted to Core ML and checked against the
original on a vault's photos:

```bash
Scripts/joytag/fetch.sh test
Scripts/joytag/evaluate.sh --vault "/Volumes/<a vault with photos>"
Scripts/joytag/fetch.sh convert
Scripts/joytag/convert.sh --vault "/Volumes/<the same vault>"
Scripts/joytag/package.sh
```

Then build the installer, which carries PhotoVault and JoyTag:

```bash
Scripts/build-installer.sh --from-source
```

Every build is checked for any trace of the Mac it was built on
(`Scripts/check-no-personal-data.sh`), and stops if it finds one.

## Project layout

| Path | What it is |
| --- | --- |
| `Sources/PhotoVault` | The app |
| `Sources/PhotoVaultCore` | Catalog, scanning, thumbnails, tagging |
| `Sources/PhotoVaultInstaller`, `Sources/PhotoVaultSetup` | The installer |
| `Sources/QuietPreferences` | Keeps AppKit from saving anything to `~/Library/Preferences` |
| `Sources/pv-prefix-keywords` | Marks keywords another tagging tool wrote into photos as that tool's |
| `Resources` | Info.plists, icon, the vault's README and default tag groups |
| `Scripts` | Builds, tests, the installer, JoyTag's conversion |
| `Tests` | Unit tests |

## Acknowledgements

Automatic tags come from [JoyTag](https://github.com/fpgaminer/joytag), under
the Apache License 2.0. Its licence ships with the model, in every installer
and every vault.

## License

All rights reserved. No licence has been chosen yet.
