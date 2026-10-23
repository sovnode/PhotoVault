// The PhotoVault User Manual's text — written from the code, then each
// chapter checked against it. See UserManualView.swift for the Markdown it
// may use. The Keyboard Shortcuts chapter is built from `Shortcut`.
enum UserManual {
    static let chapters: [Chapter] = [
        Chapter(id: "welcome", title: "Welcome to PhotoVault", symbol: "photo.on.rectangle", markdown: #"""
PhotoVault is a photo and video library that lives entirely inside one portable vault. Your photos, the app and everything it knows about them travel together. Copy the vault to another Mac or an external drive, and the whole library goes with it.

## What a vault is

A vault is a disk image: one file whose name ends in .sparsebundle. You make one with **PhotoVault Installer**. Double-click it and it opens in Finder as a disk, holding:

- **PhotoVault.app**, the app. Open it from the vault.
- **Photos**, the folder for your photos and videos, in any folders you like.
- **README.txt**, notes on looking after the vault.
- A hidden **.catalog** folder, with your albums, favorites, tags, thumbnails and settings.
- A hidden **.Tag Groups.txt** file, which sorts tags into groups.

The disk image grows as you add photos, up to the most it can hold, which you choose when you make it. It can have a password. Then nobody can open it without one, and a forgotten password can't be recovered.

PhotoVault also works in an ordinary folder, with PhotoVault.app beside a folder called Photos. This way is mostly untested.

## Three promises

- **Nothing is written outside the vault.** No preferences, caches, thumbnails or window positions go into your home folder. (Finder's icon and gallery views do make their own thumbnails there, so browse Photos in list or column view.)
- **No internet.** PhotoVault never goes online. Tagging runs on your Mac. A photo's location is shown as coordinates, never on a map.
- **Your originals stay as they are.** Albums, favorites and tags live in the catalog, not in your photos. The one exception: rotating a JPEG changes only its orientation value, never the picture. Other kinds of photo can't be rotated. PhotoVault moves a file, or fixes its permissions, only when you ask, and deletes one only when you empty the Trash.

## What it needs

- A Mac with Apple silicon, running macOS 14 or later.
- Automatic tagging needs macOS 15 or later, and a vault set up with photo tagging included. Everything else works without it.

## A tour of the window

The **sidebar** lists your library. Under **Library** are **All Media**, which opens to show the folders in Photos that hold photos, then **Favorites** and **Trash**. **Albums** and **Smart Albums** follow once you have some, with the **New Album** button at the bottom.

The **grid** shows thumbnails of whatever you picked in the sidebar. Videos show a play symbol and their length. Favorites show a heart.

The toolbar above the grid holds, from left to right: the **All**, **Photos** and **Videos** switch (⌘1, ⌘2, ⌘3); the status line; in a smart album, **Edit Filter**; the **Sort** menu and its direction button (⌥⌘↑, ⌥⌘↓); the play button, which scrolls the grid by itself (Space); and the thumbnail size slider (⌘+, ⌘−). The status line counts what you're looking at or have selected. While PhotoVault is busy, it shows progress and a **Stop** button (⌘.).

Double-click a thumbnail, or pick one and press ⇧ on its own, to open the **viewer**. It fills the window with one photo or video. Move the pointer to show its buttons along the top. Click **Library**, or press Esc or ⇧, to go back.

PhotoVault remembers where you were. Next time it opens on the same view, at the same place, and reopens the photo you were viewing. That, too, is kept in the vault.

**Help › PhotoVault User Manual** (⌘?) opens this manual. **Help › Keyboard Shortcuts** (⌘/) lists every shortcut.

The manual opens in a window of its own, so it can stay open beside your photos. Its chapters are listed on the left. To find something, type in **Search the manual** at the top of that list: only the chapters that contain every word you type stay listed.
"""#),
        Chapter(id: "start", title: "Getting Started", symbol: "play.circle", markdown: #"""
PhotoVault keeps your photos in a *vault*: a disk image that holds your photos and videos, with PhotoVault inside to show them. This chapter takes you from the download to your first look at your library, and back out again.

## Opening PhotoVault Installer

PhotoVault Installer makes new vaults. It also puts PhotoVault on vaults you already have. It comes as a zip file. Double-click the zip to unpack it, then double-click **PhotoVault Installer**.

The installer isn't notarized by Apple. So the first time you open it, macOS may say it can't check it for malicious software, and won't open it. To open it anyway:

1. Close the message. Don't move the installer to the Trash.
2. Open **System Settings** and choose **Privacy & Security**.
3. Scroll down to the message about PhotoVault Installer and click **Open Anyway**.
4. Confirm when macOS asks again. It may ask for your Mac's login password.

You only need to do this once.

The top of the window shows the installer's version. Below it are two choices: **Create a New Vault** and **Install on an Existing Vault**. Create a New Vault is already chosen when the installer opens. Click one, fill in the form below it, then click the button at the bottom right, or press ↩.

If the installer says "This installer can't be used", part of it is missing. Download it again.

## Creating a new vault

Choose **Create a New Vault**. It makes a new disk image, with PhotoVault and an empty Photos folder.

### Name

Type a name for the vault in **Name:**. It starts as "PhotoVault". The name is used twice: the disk you see in Finder has that name, and so does its disk image. For example, a vault called "Holidays" is a disk called "Holidays", in a disk image called `Holidays.sparsebundle`. The note under the field shows both.

A name can't be empty. It can't contain / or :, can't start with a full stop, and can't be too long. It also can't be the name of a vault that's already in the folder you save in. If something is wrong, the note under the field turns orange and says what.

### Save in

**Save in:** is where the disk image is saved. It starts as your home folder. Click **Choose…** to pick another folder. You can make a new folder there too. The line underneath shows the folder and how much space is free on its disk.

If the folder is in iCloud Drive, an orange warning appears: every photo in the vault would be uploaded to iCloud. The installer still lets you create the vault there, but choose a folder outside iCloud Drive. If your Mac keeps your Desktop and Documents folders in iCloud, avoid those too.

### Size

In **Size:**, choose the most the vault can hold: 50 GB, 100 GB, 250 GB, 500 GB, 1 TB or 2 TB. It starts at 500 GB.

This is a limit, not a reservation. The disk image takes only the space its photos use, and grows as you add more. So pick a size with room to spare. Whatever size you pick, the disk image can only grow into the free space on the disk it's saved on.

### Password

**Protect with a password** is off to start with. Then anyone with the disk image can open the vault.

Tick it to protect the vault. Type a password in **Password**, then again in **Type it again**. **Create Vault** stays greyed out until both are filled in and match. Once you've typed a password, an orange note says what's still missing: "Type it again to confirm it." or "The two passwords don't match." A password shorter than 8 characters gets a warning that it's easy to guess, but you can still use it.

Read the orange warning before you go on. It matters:

- Without the password, nobody can open the vault or see its photos, on this Mac or any other.
- A forgotten password can't be recovered. The photos would be lost with it.
- Keep the password somewhere safe, such as a password manager.

When you open a protected vault, macOS offers to remember the password in your keychain. That's convenient on your own Mac. But then anyone using your account can open the vault.

The installer hands the password to macOS, which encrypts the disk image. The installer then forgets it.

### Tagging

**Include photo tagging (JoyTag)** is ticked to start with. JoyTag looks at each photo and names what it sees, so smart albums can pick photos by what's in them. It runs on your Mac and never changes your photos. The note under the box says how much space it takes on the vault: about 370 MB.

Untick it to save that space. PhotoVault then won't tag photos, so smart albums can't pick photos by what's in them. You can add tagging later by installing again with the box ticked.

JoyTag needs macOS 15 or later. On macOS 14, PhotoVault works without it. For more about tags, see Smart Albums and Automatic Tags.

### Creating it

Click **Create Vault** (↩). **Create Vault** is greyed out while the name or the password has a problem. The installer ticks off each step as it goes: "Creating the disk image", "Opening the vault", "Installing PhotoVault", "Copying PhotoVault's files" and "Checking". "Copying PhotoVault's files" appears only when tagging is ticked. It takes a minute or so.

While the installer works, you can't close its window. If you try to quit, it says "The installer is still working". Wait until it's done.

## Installing on an existing vault

Choose **Install on an Existing Vault** to put this version of PhotoVault on a vault you already have. Use it to update PhotoVault, to put a fresh copy in place, or to add or take off photo tagging. The vault's photos, albums and tags stay as they are.

### Choosing the vault

Vaults that are open appear in the **Vault:** menu by themselves. If more than one is open, choose the one you want. The line under it shows where its disk image is. To pick a vault that isn't in the menu, click **Choose…** beside it.

If no vault is open, the form says "No vault is open". Click **Choose…** and pick the vault's disk image: the file ending in `.sparsebundle`. Or drag the disk image onto the dashed box. If the vault is already open, you can choose the vault's disk itself. The installer opens the disk image if it needs to, and says "Opening" and the vault's name while it does.

If what you chose has no Photos folder, the installer says it isn't a PhotoVault vault. To make one, create a new vault instead.

### A vault with a password

If the vault is protected and isn't open yet, the installer says it's protected with a password. Type the password and click **Open**, or press ↩. If it's wrong, the installer says "That password isn't right."

You can also open the vault first by double-clicking its disk image. macOS asks for the password, and the vault then appears in the **Vault:** menu.

### What the installer will do

Under the vault, a few lines say what installing will do. The button at the bottom changes to match. The version numbers below are only examples:

- "PhotoVault 1.6.0 is on it, and is updated to 1.7.0." The button says **Update**.
- "PhotoVault 1.7.0 is on it already. A fresh copy goes in its place." The button says **Reinstall**.
- "It has a newer PhotoVault, 1.8.0. Installing puts the older 1.7.0 in its place." This line has an orange warning sign. The button says **Install Older Version**.
- "PhotoVault isn't on it yet." The button says **Install**.

The installer doesn't ask again before installing an older version. So read these lines before you click.

Another line says "Its photos, albums and tags stay as they are." If PhotoVault has never opened the vault, it says just "Its photos stay as they are." The installer never touches the Photos folder, or the albums, favorites and tags PhotoVault keeps. It checks them before it finishes. It does replace README.txt at the top of the vault with the current one, so don't keep your own notes in it.

Your tag groups file, .Tag Groups.txt, is kept as it is. On a vault from an older version, where the file was called Tag Groups.txt and could be seen in Finder, the installer renames it to the hidden .Tag Groups.txt. The done screen tells you when that happens.

### If PhotoVault is open

If PhotoVault is open from that vault, a line with a blue information sign says so: "PhotoVault is open from it. The installer quits it first; a scan or tagging run carries on when it's next opened." The installer quits PhotoVault without asking. A scan or tagging run carries on the next time PhotoVault opens. A move or a re-tag stops where it is: photos already moved stay in their new folder, and photos already re-tagged keep their new tags.

It's best to quit PhotoVault yourself first, with ⌘Q, so nothing you're in the middle of is cut short. If PhotoVault doesn't quit within about 15 seconds, the installer stops and asks you to quit it and try again.

### Tagging

The **Include photo tagging (JoyTag)** box works as it does for a new vault:

- Ticked, on a vault that already has JoyTag: the note says it's on this vault already.
- Ticked, on a vault without JoyTag: JoyTag is added. The note says how much space it takes.
- Unticked, on a vault without JoyTag: the note says how much space that saves. PhotoVault won't tag photos.
- Unticked, on a vault that has JoyTag: the note turns orange. JoyTag will be taken off the vault, freeing its space. PhotoVault won't tag new photos. The tags it has already made are kept, and smart albums that use them still work. Install again with the box ticked to bring it back.

### Installing

Click **Install**, **Update**, **Reinstall** or **Install Older Version** to start, or press ↩. The installer ticks off each step as it goes. "Quitting PhotoVault" appears if PhotoVault was open from the vault. It takes a minute or so.

## When the installer is done

When a new vault is ready, the installer says so, with the vault's name. The vault is already open in Finder, as a disk with the vault's name. The installer also says where its disk image is. If you protected it, the installer reminds you that macOS asks for the password each time the vault is opened. Under **Next:** are three steps:

1. Copy your photos and videos into its Photos folder.
2. Open PhotoVault from the disk. It finds the photos and makes their thumbnails.
3. When you're done, eject the disk from inside PhotoVault, with ⌘E.

The rest of this chapter goes through each step.

After installing on an existing vault, the installer says which version of PhotoVault is now on the vault and what it replaced. It confirms that the vault's photos, albums and tags are as they were. If it had to quit PhotoVault, it says so: open PhotoVault again to carry on. If you took tagging off, it says how much space that freed. If it renamed Tag Groups.txt, it says how to show hidden files in Finder: press ⇧⌘ and the full stop key.

Three buttons sit at the bottom:

- **Show in Finder** shows the vault in Finder. For a new vault it selects the Photos folder, ready for your photos. After an install it selects PhotoVault.app.
- **Done** (Esc) quits the installer.
- **Open PhotoVault** (↩) opens PhotoVault from the vault and quits the installer.

If something goes wrong, the installer says what happened, under a title such as "The vault couldn't be created" or "PhotoVault couldn't be installed". Click **Back** (↩) to return to the form. See Troubleshooting for what the messages mean.

You don't need the installer again until you want another vault, a newer version of PhotoVault, or to add or take off photo tagging. To update, open a newer PhotoVault Installer and choose **Install on an Existing Vault**.

## Adding photos and videos

PhotoVault shows what's in the vault's **Photos** folder. To add photos and videos, copy them there in Finder:

1. Open the vault's disk in Finder. It's in the Finder sidebar, under Locations, with the vault's name.
2. Open the **Photos** folder.
3. Drag your photos and videos in, or whole folders of them. Finder copies them from another disk and leaves the originals where they were.

Use any folders you like inside Photos, as many levels deep as you like. PhotoVault shows them in its sidebar, under All Media, just as they are on the disk.

Anything outside the Photos folder isn't shown. Hidden files are skipped.

When you look in the Photos folder in Finder, use list or column view. Icon and gallery view make macOS keep small copies of your pictures in your home folder, outside the vault. See Your Vault.

### Which files PhotoVault shows

- Photos: JPEG (.jpg and .jpeg), PNG, HEIC and HEIF, GIF, TIFF (.tif and .tiff), BMP and WebP.
- Videos: .mov, .mp4, .m4v, .avi, .mkv, .webm, .mpg, .mpeg and .3gp.

Capital letters in the file extension don't matter. Other files, such as RAW camera files or documents, stay where they are but don't appear in PhotoVault.

Some videos can't be played on a Mac, such as many MKV files and older AVI files. They still appear, marked with a question mark. See Viewing Photos and Videos.

## Opening PhotoVault

Double-click **PhotoVault.app** at the top of the vault's disk.

Always open PhotoVault from there. PhotoVault finds your photos by looking around the place it was opened from. A copy somewhere else, such as in your Applications folder, can't find the vault. It says "No .catalog folder found alongside the app. Move PhotoVault.app to the top level of the vault." and the status line says "Not ready". Keep PhotoVault.app at the top level of the vault.

The library window opens. The status line, in the middle of the bar at the top of the window, says what PhotoVault is doing.

## The first scan

The first time PhotoVault opens a vault, it looks through the whole Photos folder. The status line says "Scanning all folders…". Then it makes thumbnails, with a progress bar and a count, for example "Building thumbnails — 1,234 of 1,234". After that it reads any tags already written into the photos, such as keywords added by another app: "Reading tags — 1,234 of 1,234". While the window has nothing to show yet, it says "Scanning…".

Thumbnails are the small pictures in the grid. PhotoVault makes one for every photo and video. It keeps them inside the vault, so they travel with it, and nothing goes into your home folder. For a big library the first scan can take a while. Later openings are much quicker, because the thumbnails are already made.

While the scan runs, a **Stop** button sits beside the status line. To stop the scan, click it, press ⌘., or choose Vault › Stop Scan. The thumbnails made so far are kept, and the scan carries on the next time PhotoVault opens.

When the scan is done, your photos and videos fill the window. The status line shows how many items there are, such as "1,234 items". To find your way around, see Browsing Your Library.

Each later time you open the vault, PhotoVault takes a quick look for changes. The status line says "Checking for changes…", and the Stop button shows briefly. If PhotoVault didn't close properly last time, for example because the disk was pulled out or the Mac lost power, it looks through every folder again instead, and the status line says "Scanning all folders…". That takes longer, but the thumbnails already made are kept.

If PhotoVault has nothing to show, the window says "Nothing here yet". It asks you to drop files into the Photos folder, then choose Rescan. The command it means is Vault › Rescan Changed Folders (⌥⌘R).

## Tagging your photos

If the vault has photo tagging, PhotoVault offers to tag the photos JoyTag hasn't seen yet. It does this each time a scan finishes:

- 100 new photos or fewer: tagging starts straight away, without asking.
- More than 100: PhotoVault asks first, for example "Tag 1,234 photos with JoyTag?". The question says roughly how long tagging will take.

Click **Tag Photos** to start, or **Not Now** to leave it. After Not Now, PhotoVault doesn't ask again until the next time it opens. To start sooner, choose Image › Classifier › Tag Untagged Photos. If every photo is tagged already, the status line says "Every photo is tagged".

While JoyTag works, the status line says "Loading JoyTag…", then "Tagging with JoyTag", with a count and a progress bar. You can keep browsing in the meantime. When it's done, the status line says how many photos were tagged, such as "Tagged 1,234 photos with JoyTag".

- Tick **Tag faster** to finish sooner. The Mac gets busier, and the box is unticked again next time.
- Click **Stop**, press ⌘., or choose Vault › Stop Tagging to stop. Tagging carries on the next time PhotoVault opens.

JoyTag's tags are kept in PhotoVault's catalog. Your photos themselves are never changed. See Smart Albums and Automatic Tags.

On macOS 14, or on a vault where tagging was left out, PhotoVault doesn't tag photos. Image › Classifier says why. To add tagging to a vault, open PhotoVault Installer and install on the vault with **Include photo tagging (JoyTag)** ticked.

## Rescanning

PhotoVault looks for changes each time it opens. If you add or remove photos in Finder while it's open, tell it to look again:

- Vault › Rescan Changed Folders (⌥⌘R) looks in the folders that have changed. It's quick, and right for photos you've added or taken away.
- Vault › Full Rescan (⌥⇧⌘R) looks at every folder and every file. Use it if you changed a photo in another app and PhotoVault still shows the old one. Changing a photo where it is doesn't change its folder, so Rescan Changed Folders can miss it.

Both are greyed out while a scan, a tagging run or a move is under way. If a rescan finds photos JoyTag hasn't seen, it can lead to the tagging question too, unless you clicked Not Now since PhotoVault opened.

Take care: ⌘R on its own is Rotate Right, not a rescan.

## Ejecting the vault

When you're done, choose Vault › Eject Volume (⌘E). PhotoVault closes its catalog safely, quits, and ejects the vault's disk a moment later.

Eject from inside PhotoVault, not from Finder. PhotoVault runs from the vault itself, so macOS can't eject the disk while PhotoVault is open. Finder says the disk is in use. ⌘E quits first and then ejects, which is the only order that works.

If you try Finder's eject while PhotoVault is open, PhotoVault lets go of its catalog and can't carry on. Quit it with ⌘Q, then eject the disk in Finder.

You can also quit PhotoVault first, with ⌘Q, and then eject the disk in Finder, as you would any disk.

If PhotoVault is scanning, tagging or moving photos when you press ⌘E, it asks first. The question says what happens to the unfinished work. Click **Stop and Eject** to stop and eject. Or click **Keep Scanning**, **Keep Tagging** or **Keep Moving** to let it finish. Quitting with ⌘Q at such a time asks the same way, with **Stop and Quit**.

A few more things to know:

- If the disk is still there a few seconds after ⌘E, something else is still using it, often macOS finishing with a video. Wait a moment, then eject it in Finder. See Troubleshooting.
- If the vault's disk image is on an external drive, ⌘E ejects only the vault. Eject the drive in Finder afterwards.
- ⌘E doesn't remember the window's size and position. Quitting with ⌘Q does.
- If your vault is an ordinary folder rather than a disk image, ⌘E ejects the whole drive the folder is on, if it's an external drive. See Your Vault.

## Opening the vault again

1. In Finder, find the vault's disk image, for example `PhotoVault.sparsebundle`. It looks like a single file. Unless you chose another folder, it's in your home folder. In Finder, choose Go › Home to get there.
2. Double-click it. If the vault is protected, macOS asks for its password. It offers to remember the password in your keychain. That's convenient on your own Mac, but then anyone using your account can open the vault.
3. The vault's disk appears in Finder. Open it and double-click PhotoVault.app.

PhotoVault opens where you left it. You see the same view, scrolled to the same place, and the photo that was open is open again. PhotoVault takes a quick look for changes as it opens.

To open the vault on another Mac, or to copy it, see Your Vault.
"""#),
        Chapter(id: "browse", title: "Browsing Your Library", symbol: "square.grid.3x3", markdown: #"""
The library window is where you browse. The sidebar on the left lists the places you can look: all your photos and videos, the folders they are in, your favorites, the Trash and your albums. On the right is the grid of thumbnails, with a row of controls above it.

## The sidebar

Click any item in the sidebar to show it in the grid. The **Library** section at the top holds All Media, Favorites and the Trash. Your albums and smart albums are listed below it.

### All Media and your folders

**All Media** shows every photo and video in your vault, except those in the Trash. The number beside it counts them all, whatever the grid is set to show.

All Media is also the top of your folder tree. Click the small arrow beside it to see the folders inside your Photos folder, nested just as they are on the disk. Folders are listed in name order, and numbers go by their value, so "Trip 9" comes before "Trip 10". A folder is listed only if it has photos or videos in it, or in a folder inside it. An empty folder does not appear.

Choosing a folder shows everything in it **and in all of its subfolders**. The number beside a folder counts the same way: everything in the folder and below it. Rest the pointer on a folder to see its count. If some of its photos are in subfolders, this also tells you how many are directly in the folder itself.

### Favorites and the Trash

**Favorites** shows every photo and video you have marked as a favorite, except those in the Trash. It has no number beside it. Favorites and Albums explains how to mark them.

**Trash** shows what you have moved to the Trash. Its icon looks full when something is in it, and the number beside it says how many items it holds. That number can be a little higher than what the grid shows, because it also counts items whose files have since gone missing from the disk. To empty it, right-click the Trash and choose **Empty Trash…**, or choose Vault › Empty Trash…. Organizing Files explains putting things back and emptying the Trash.

### Albums and Smart Albums

An **Albums** section appears once you have made an album, and a **Smart Albums** section once you have made a smart album. The number beside an album counts the photos and videos in it. Smart albums have no number. A number of zero is never shown in the sidebar.

To make an album, click **New Album** at the bottom of the sidebar, or choose File › New Album… (⌘N). Favorites and Albums and Smart Albums and Automatic Tags explain them in full.

You can ⌘-click or ⇧-click to pick several albums at once, for example to delete them together. The grid stays as it is while several rows are picked.

### Dragging photos onto the sidebar

You can drag photos from the grid onto the sidebar. If the photo you drag is selected, all the selected photos go with it. Otherwise only that one goes.

- Drop them on a folder to move the files into that folder. Drop them on All Media to move them to the top level of the Photos folder. Organizing Files explains moving.
- Drop them on an album to add them to it. The files stay where they are.

Favorites, the Trash and smart albums don't take drops. Photos in the Trash can't be dragged.

### Hiding the sidebar

To give the grid the whole window, choose View › Hide Sidebar (⌃⌘S), or click the sidebar button near the top left of the window. Choose View › Show Sidebar (⌃⌘S) to bring it back.

## The grid

The grid shows the view you chose in the sidebar as square thumbnails. They fill each row across the window, and the number in a row changes to fit. Rest the pointer on a thumbnail to see its file name.

Small marks at the bottom left of a thumbnail tell you more:

- A video shows a play symbol and its length in minutes and seconds.
- A video PhotoVault can't play shows a question mark instead of the play symbol.
- A favorite shows a heart.

A selected thumbnail has a colored border.

A square stays plain grey until its thumbnail is ready. A small photo symbol means it has no thumbnail, usually because it hasn't been made yet. A warning triangle marks a video that PhotoVault can't play and has no thumbnail for.

When a view has nothing to show, the grid says so. The Trash says "The Trash is empty", a folder says "No photos in this folder" and a smart album says "No photos match this filter". Other views say "Nothing here yet", or "Scanning…" while PhotoVault is scanning. If All Media says "Nothing here yet", put photos and videos in the Photos folder at the top of the vault. Then choose Vault › Rescan Changed Folders (⌥⌘R).

### The count above the grid

In the middle of the controls above the grid, PhotoVault shows how many items the current view holds, for example "1,234 items". This counts only what the grid shows now: this folder, this album, or only photos or only videos. It is not the whole vault.

When you have selected photos, it shows how many instead, for example "3 selected". After some actions it says what was done, for example "Moved 2 items to the Trash". These messages show only while nothing is selected.

While PhotoVault is busy scanning, tagging or moving photos, this space shows its progress and a **Stop** button.

### Thumbnail size

There are three ways to make the thumbnails bigger or smaller:

- Drag the slider at the right end of the controls above the grid.
- Pinch on the trackpad over the grid.
- Choose View › Bigger Thumbnails (⌘+) or View › Smaller Thumbnails (⌘−).

Each press of ⌘+ or ⌘− changes the size by about a quarter. They are greyed out at the biggest and smallest sizes. At the biggest size, only a few thumbnails fit across the window. Very large thumbnails can look a little soft. Open the photo to see it sharp. PhotoVault remembers the size in the vault.

### Show Whole Photos

Normally each thumbnail is a square cut from the middle of the photo, so the grid lines up neatly. To see each photo whole, at its own shape, inside its square, choose View › Show Whole Photos (⌘0). A checkmark shows it is on. Choose it again to go back. PhotoVault remembers this choice in the vault.

## Photos, videos or both

The **All**, **Photos** and **Videos** buttons at the left of the controls choose what the grid shows: everything, only photos, or only videos. You can also choose View › Show All (⌘1), View › Show Only Photos (⌘2) or View › Show Only Videos (⌘3).

**Each view keeps its own choice.** If you leave an album showing only videos, it still shows only videos the next time you open it, whatever the other views show. PhotoVault remembers this in the vault, so it lasts after you quit.

Changing this choice clears the selection.

## Sorting

To choose the order of the grid, use the **Sort** pop-up menu above the grid.

### The orders

- **Date Taken**: the date saved in the photo when it was taken, or the date a video was recorded. A file without one goes by the date it was last changed. Items with the same date go by file name.
- **Date Created**: the date the file was created, as Finder shows it. Items without one come last.
- **File Name**: by name, the way Finder sorts. Numbers go by their value, so IMG_9 comes before IMG_10, and capitals and accents are ignored. The folder counts too, because PhotoVault reads the whole path inside the Photos folder. So in All Media, every photo in a folder called "2019" comes before every photo in a folder called "2020".
- **Length**: videos by how long they play. A photo counts as having no length, so photos come first when the shortest is first and last when the longest is first.
- **Album Order**: in an album only. This is the order the photos were added to the album. Photos you add later go at the end of this order.
- **Random**: a shuffled order.

Until you choose an order, PhotoVault sorts by Date Taken, oldest first, if at least half your photos and videos carry the date they were taken. Otherwise it sorts by File Name.

### Direction and shuffling

The arrow button beside the Sort menu shows which way the order runs. Click it to turn the order round. Rest the pointer on it to see the direction: "Oldest first" or "Newest first" for dates and Album Order, "A to Z" or "Z to A" for File Name, and "Shortest first" or "Longest first" for Length. The View menu has the same two directions, named for the current order. The first is ⌥⌘↑ and the second is ⌥⌘↓.

In Random, the button shows a shuffle symbol instead. Click it, or choose View › Shuffle Again (⌥⌘↑), to get a new shuffle. You also get a new shuffle each time you choose Random from the Sort menu. Otherwise a shuffle stays as it is, even after you quit, so you come back to the same order.

When you change the order or the direction, the grid stays scrolled where it was. It does not follow the photo you were looking at to its new spot.

### Which views share a sort

- All Media, every folder, Favorites and the Trash share one sort. If you change it in one of them, it changes in all of them.
- Each album keeps its own sort. A new album starts in Album Order, with the first photo added first.
- Each smart album can keep its own sort too. Until you change the order or the direction in a smart album, it follows the sort of All Media.

PhotoVault keeps every sort in the vault.

## Picking up where you left off

Every view remembers its place, which is the photo at the top left of the grid. All Media, Favorites, the Trash and each folder, album and smart album have a place of their own. So do their All, Photos and Videos choices. Scrolling one view never moves another. When you come back to a view, it opens at the place where you left it.

If the photo a view remembers has gone from it, the view opens at the top. With Photos or Videos chosen, a view that has no place of its own yet, or whose photo has gone, starts at the place of All if that photo is shown. Otherwise it starts at the top.

When you open PhotoVault again, it opens where you left it: the same view, the same All, Photos or Videos choice and the same place. If a photo or video was open in the viewer, it opens again. If the album or folder you were in no longer exists, PhotoVault opens All Media instead. The window also comes back at the size and position you left it, unless you quit while it was in full screen.

All of this is kept in the vault itself, so it goes with the vault to another Mac.

## Selecting photos

### With the mouse

PhotoVault selects photos the way Finder does:

- Click a photo to select only that photo.
- ⌘-click a photo to add it to the selection, or to take it out.
- ⇧-click to select every photo from the one you last clicked without ⇧ up to this one. ⇧-click again to make that range longer or shorter.
- ⌘⇧-click to add a range to what is already selected.
- Click an empty part of the grid, such as the space after the last photo, to select nothing.
- Choose Edit › Select All (⌘A) to select everything in the view, or Edit › Deselect All (⇧⌘A) to select nothing.
- Double-click a photo or video to open it. Viewing Photos and Videos explains the viewer.

Choosing another view, or switching between All, Photos and Videos, clears the selection.

### With the keyboard

When exactly one photo is selected, you can use these keys:

- Press ← or → to select the photo before or after it. They run on from the end of one row to the start of the next.
- Press ↑ or ↓ to select the photo directly above or below it.
- Press and release ⇧ on its own to open the photo. Holding ⇧ down for more than a moment does nothing. In the viewer, ⇧ on its own takes you back to the library.

The grid scrolls just enough to show the photo you move to. This is a quick way to go through photos one by one, for example to rotate them with ⌘L and ⌘R.

At the edge of the grid the arrow keys do nothing: ← on the first photo, → on the last one, and ↑ in the top row. ↓ also does nothing when there is no photo directly below, for example above a short last row.

The arrow keys move only a single selection. With no photo selected, or several, they do nothing. Holding ⇧ with an arrow key does not add to the selection.

When the sidebar has the keyboard (after you click in it), the arrow keys move through the sidebar instead. Click a photo in the grid to give them back to the grid.

## Scrolling automatically

PhotoVault can scroll the grid down slowly by itself, so you can sit back and look.

To start, press Space, click the play button above the grid, or choose View › Scroll Automatically. To pause, press Space again, click the pause button, or choose View › Pause Scrolling. Space works even when the sidebar has the keyboard. When you are typing in a field, Space types a space. In the viewer, Space plays and pauses a video instead. The play button is greyed out when the view is empty.

To set the speed, click the small arrow beside the play button, or choose View › Scrolling Speed. You can choose 2, 5, 10, 20, 40 or 80 rows a minute, and it starts at 10. The speed counts rows of thumbnails, so the pace is the same at any thumbnail size. Changing the speed doesn't pause the scrolling. PhotoVault remembers the speed in the vault.

It pauses by itself when you:

- scroll the grid, or click or right-click in it (the click still does its usual job)
- press a key, other than Space or a shortcut with ⌘
- open a photo or video
- choose another view, or switch between All, Photos and Videos

You can still change the thumbnail size with ⌘+ and ⌘− while it scrolls.

It stops on its own at the bottom of the grid. If you start it at the bottom, it goes back to the top first. Your place follows the scrolling, so the view comes back where it stopped. Your Mac's display stays awake while it scrolls. PhotoVault always opens with scrolling paused.

## The right-click menu

Right-click a thumbnail for a menu of things to do with it.

If the photo you right-click is part of a selection of several, the menu acts on all of them and says how many, for example "Move 5 Photos to Trash". Otherwise it acts only on the photo you right-clicked. **Watch out:** if you right-click a photo outside the selection, the menu acts on that one photo, even though the highlight stays on the selection. The menu says "Photo" for videos too.

Outside the Trash, the menu holds:

- **Add Photo to Favorites** (.), or **Remove Photo from Favorites** when every photo it acts on is already a favorite.
- **Add Photo to Album**, with **New Album…** and then each of your albums.
- **Remove Photo from This Album**, in an album only. The photo stays in your library.
- **Rotate Left** (⌘L) and **Rotate Right** (⌘R). Only JPEG photos can be rotated. If several photos are picked, only the JPEGs among them turn. These are greyed out when none of them is a JPEG.
- **Re-tag with JoyTag**. Smart Albums and Automatic Tags explains tagging.
- **Move Photo to Folder**, with **New Folder…**, **Photos (top level)** and your folders.
- **Move Photo to Trash** (⌘⌫). It doesn't ask first.
- **Show in Library**, when you right-click a single photo in any view except All Media and the Trash.
- **Reveal in Finder (list view only)**, which shows the files in Finder.

Re-tag and Move to Folder are greyed out while PhotoVault is busy scanning, tagging or moving photos. Re-tag is also greyed out when photo tagging isn't available on this vault.

In the Trash, the menu holds only **Put Back Photo** and **Reveal in Finder (list view only)**.

When you look at your vault in Finder, keep Finder in list or column view. Finder's icon and gallery views make macOS keep small previews of your photos on the Mac, outside the vault.

## Show in Library

When you're in a folder, an album, a smart album or Favorites, **Show in Library** takes you to the same photo in All Media, where you can see the photos around it. To use it, right-click a single photo and choose **Show in Library**, or select one photo and choose Image › Show in Library. It also works on the photo that is open in the viewer.

All Media opens with the photo selected and scrolled into view. If All Media was showing only photos or only videos, and that would hide this item, it goes back to showing all. Show in Library doesn't work for photos in the Trash.
"""#),
        Chapter(id: "viewer", title: "Viewing Photos and Videos", symbol: "eye", markdown: #"""
## Opening a photo or video

There are two ways to open something in the viewer:

- Double-click its thumbnail in the grid.
- Click a thumbnail once so that it is the only item picked. Then press ⇧ (Shift) on its own and let go straight away. Holding ⇧ down for longer doesn't count. Neither does pressing another key, clicking or scrolling while you hold it.

The viewer fills the whole window, sidebar included, on a black background. A video starts playing as soon as it opens.

If you quit PhotoVault while a photo or video is open in the viewer, PhotoVault opens the same view and the same item again the next time you start the app.

## The header

At first the viewer shows only the photo. When you move the pointer, a bar appears across the top of the window. This manual calls it the header. It disappears again about 2.5 seconds after the pointer stops. It also stays hidden while you step through photos with the arrow keys. To click one of its buttons, move the pointer first so the header shows.

From left to right, the header has:

- **Library**, which takes you back to the library.
- **‹** and **›**, which show the previous and next item.
- The file's name.
- **Repeat** (looping arrows) and **Play Next** (a play arrow against a bar). A button that is switched on is drawn in color on a faint, lighter patch.
- A timer menu showing how long each photo stays, such as **5 s**. It appears only while Play Next is on.
- **Rotate Left** and **Rotate Right**.
- A trash can for **Move to Trash**. For something already in the Trash, this becomes **Put Back** instead.
- A heart. It turns red and filled when the item is one of your Favorites.
- An info button (a small "i" in a circle), which shows and hides the properties panel.

To find out what a button does, rest the pointer on it. The tip also gives the button's keyboard shortcut, if it has one. For example, the tip for **Library** shows Esc or ⇧.

## Stepping from one item to the next

- Press → or click **›** to see the next item. **Image › Next Photo** (→) does the same.
- Press ← or click **‹** to see the previous item. **Image › Previous Photo** (←) does the same.

These also work for videos, although the menu items say "Photo".

Stepping follows the view you opened the item from, whether that is All Media, a folder, an album, a smart album, Favorites or the Trash. It uses that view's All, Photos or Videos setting and its sort order. Each item you step to is also picked in the grid behind the viewer. At the first or last item nothing happens, because stepping doesn't wrap round to the other end.

The arrow keys also work while a photo is zoomed in, and the next photo opens fitted to the window. They work while a video is playing too: ← and → move to another item instead of skipping through the video. ↑ and ↓ don't step.

PhotoVault gets the photos on either side ready in advance, so a step usually lands on a sharp photo. If a photo isn't ready yet, it first appears from its thumbnail and sharpens a moment later. If you hold an arrow key down to race through photos, they may show only as thumbnails until you stop.

Sometimes the item on screen leaves the view you opened it from while it is open. For example, you might remove it from Favorites while you are looking through Favorites, or move it out of the folder you are viewing. The item stays on screen, but ← and → stop working, and so does Play Next. Go back to the library and open a photo again to carry on.

## Going back to the library

Any of these takes you back:

- Press Esc. This works while a video is playing too.
- Press ⇧ on its own and let go straight away.
- Click **Library** in the header.
- Choose **Image › Back to Library** (Esc).

The grid then scrolls so that the last item you looked at is in the top row, wherever the arrow keys took you. Going back also turns Play Next off, which ends a slideshow.

Clicking the photo itself doesn't close the viewer.

## Full screen

To fill the screen, choose **View › Enter Full Screen**, or click the green button at the top left of the window. When the header hides, you see only the photo.

In full screen, Esc takes you back to the library and the window stays in full screen. To leave full screen, move the pointer to the top of the screen to show the menu bar, then choose **View › Exit Full Screen**.

A video's own controls have a full-screen button as well. It shows the video by itself, without PhotoVault's header.

## Zooming in

### Photos

- To zoom in and out, pinch on the trackpad. The spot under the pointer stays where it is as the photo grows or shrinks. You can zoom in up to 12 times, but never out past the size that fits the window.
- To jump between the fitted size and twice the size, double-tap with two fingers. This needs Smart zoom turned on in your Mac's trackpad settings.
- With a mouse, hold ⌘ and scroll.

While you are zoomed in, the pointer becomes an open hand. To move around the photo, scroll with two fingers or click and drag. The photo stops at its own edges.

The viewer has no zoom keys. ⌘+ and ⌘− change the size of the thumbnails in the library, and they don't work in the viewer.

The zoom goes back to fitted when you move to another photo or rotate the photo. A photo you come back to also opens fitted.

Very large photos are shown at up to 6,000 pixels along their longest side. If the original is bigger than that, zooming right in shows a little less detail than the file holds.

### Videos

Pinch zooms a video too, and two fingers move it around while it is zoomed. Every video starts unzoomed, including one you open again. A video that loops with Repeat keeps its zoom.

## The properties panel

To show or hide the panel, press ⌘I, click the info button in the header, or choose **Image › Show Properties** or **Image › Hide Properties**. The panel opens down the right-hand side, and the photo shrinks to fit the space left. The panel stays open as you step from item to item, even while the header is hidden. PhotoVault remembers whether you left it open for this vault, and shows it the same way next time.

The panel only shows information, and you can't change anything in it. You can select each detail, such as the file name or the folder, and copy it.

The panel shows these sections, with their headings in capitals:

- **FILE**: the file's **Name**, its **Folder** (for example "Photos › Holidays"), its **Size** and its **Format**, such as "JPEG image".
- **DATE**: **Taken** is the date stored inside the photo or video. If there isn't one, you see **Modified**, the date the file was last changed, with the note "The photo itself carries no date." **Created** is the file's creation date as Finder shows it, when the file has one.
- **IMAGE** (or **VIDEO**): the **Dimensions** in pixels, the right way round, or "Unknown". A video also shows its **Duration**, when it is known. If PhotoVault can't play a video, this section says "This file can't be played."
- **CAMERA**: only for photos that record it. It shows the **Camera**, the **Lens** and the **Exposure**: aperture, shutter speed, ISO and focal length, as far as the photo records them.
- **LOCATION**: only for photos that record where they were taken. The **Coordinates** appear as text, with the note "Shown as text only; no map is loaded." PhotoVault never loads a map, because drawing one would mean sending the location over the internet.
- **LIBRARY**: **Favorite** says Yes or No. **Albums** lists the albums the item is in, or says None. Smart albums aren't listed here. An item in the Trash also shows "In the Trash."
- **TAGS**: the item's tags, grouped by where they came from. **JoyTag** comes first, with the version and the date it tagged the photo, when these were recorded. Tags from any other tagging tool come next. **Keywords already in the photo** comes last. If there are none, you see "No tags."

R18 tags appear here only when **Image › Classifier › Show R18 Tags** is ticked. When it isn't ticked, the panel doesn't say that any tags were left out. Smart Albums and Automatic Tags explains tags and the R18 group.

If you add the photo to an album while the panel is open, the Albums line doesn't change straight away. It catches up when you step to another item and back, or hide the panel and show it again.

## Videos

A video starts playing as soon as it opens. When you move the pointer over it, the standard macOS video controls appear, including play and pause, a timeline, volume and a speed menu. Space plays and pauses too.

PhotoVault uses one playback speed for every video. When you pick a speed from the speed menu in the video's controls, the next video plays at that speed too. PhotoVault remembers the speed for this vault until you pick another.

When a video ends, it stops at the end, unless Repeat or Play Next is on:

- With **Repeat** on, it starts again from the beginning.
- With **Play Next** on, the next item opens.

Some videos can't be played. Instead of the video, the viewer shows "No playable video track", with a short explanation that macOS can't open this kind of file. MKV, VP9 and older DivX-style AVI files are among them. The file itself is left as it is. In the grid, these videos show a question mark where the play symbol would be.

Videos can't be rotated.

## Repeat, Play Next and slideshows

Repeat and Play Next each have a button in the header, a key and an item in the Image menu. They only work in the viewer.

- **Repeat** (R, or **Image › Repeat**) loops the video on screen. In a slideshow, it starts again from the first item when the end is reached. On its own, it does nothing for a photo.
- **Play Next** (N, or **Image › Play Next**) moves on to the next item when a video ends. For photos, it makes a slideshow: each photo stays on screen for the time you choose, then the next item opens.

Going back to the library turns Play Next off. Repeat stays on until you turn it off or quit. PhotoVault doesn't remember either of them the next time it opens.

### Showing a slideshow

1. In the library, go to the folder, album, smart album or other view you want to show. To leave videos out, choose **View › Show Only Photos** (⌘2).
2. Open the first photo.
3. Press N, or click **Play Next** in the header.
4. To change how long each photo stays, choose a time from the timer menu in the header: 2, 3, 5, 10, 20 or 30 seconds. It starts at 5 seconds, and PhotoVault remembers your choice for this vault.

While the slideshow runs:

- It shows the items in the view's own order. Each new photo replaces the last one straight away, with no fade.
- Videos play to the end, then the slideshow moves on. A video that can't be played stays on screen for the same time as a photo.
- If Repeat is also on, a video loops instead of moving on, so the slideshow stays on it until you press →.
- You can step with ← and → at any time. The slideshow carries on from wherever you are, and each item gets the full time.
- Your Mac's display doesn't go to sleep. It can sleep normally again once Play Next is off or you go back to the library.
- At the last item, the slideshow stops and the viewer stays open. With Repeat on, it starts again from the first item.

If you switch Play Next on after a video has already finished, press → to move on.

### A random slideshow

The viewer has no shuffle button. To show a view in random order, sort it at random first:

1. In the library, choose **Random** from the **Sort** pop-up in the toolbar. Browsing Your Library explains sorting.
2. Open the first photo in the grid.
3. Press N to start the slideshow. Turn on Repeat as well if you want it to keep going round. With Repeat on, a video loops and the slideshow stays on it, so you may want **View › Show Only Photos** (⌘2) first.

PhotoVault keeps a random order until you ask for a new one, so the same shuffle comes back next time. For a fresh order, go to the library before you open the first photo. Then choose **View › Shuffle Again** (⌥⌘↑), or click the shuffle button beside the **Sort** pop-up. Choosing **Random** after another sort order also gives a new shuffle.

## Favorites

To add the item on screen to your Favorites, or take it out again, do any of these:

- Press . (full stop).
- Click the heart in the header.
- Choose **Image › Add to Favorites** or **Image › Remove from Favorites**.

The heart turns red and filled when the item is a favorite. In the viewer, these act only on the item on screen, whatever else was selected in the grid. Favorites and Albums explains Favorites in full.

## Rotating

To turn a photo a quarter turn, press ⌘L (**Rotate Left**) or ⌘R (**Rotate Right**). You can also click **Rotate Left** or **Rotate Right** in the header, or choose **Image › Rotate Left** or **Image › Rotate Right**.

Only JPEG photos can be rotated. For other kinds of photo, and for videos, the rotate buttons and menu items are greyed out. PhotoVault changes only the setting in the file that says which way up the photo goes, and the picture itself isn't saved again. If a photo can't be changed, for example because the file is read-only, PhotoVault shows a message saying why. To undo a rotation, rotate the other way. Organizing Files has more about rotating.

## Move to Trash and Put Back

To move the item on screen to the Trash, press ⌘⌫, click the trash can in the header, or choose **Image › Move to Trash**. PhotoVault doesn't ask first. The next item appears, or the previous one if you were at the end. If nothing is left in the view, you go back to the library.

An item in the Trash disappears from every other view and is taken out of every album. Its file stays where it is on the disk until you empty the Trash with **Vault › Empty Trash…**. If you put it back later, it is still a favorite if it was one, but it doesn't go back into its albums. Organizing Files explains the Trash in full.

To put an item back, choose **Trash** in the sidebar and open the item. The header then shows **Put Back** in place of the trash can. Click it to return the item to your library. The next item in the Trash appears, or the previous one if you were at the end. If the Trash is now empty, you go back to the library. Put Back has no keyboard shortcut and no menu item.

For an item in the Trash, the rotate buttons are greyed out. So are **Image › Add to Favorites**, **Image › Move to Folder**, **Image › Move to Trash** and **Image › Show in Library**.

## The right-click menu

Right-click a photo in the viewer, or Control-click it, for two commands:

- **Add to Album** adds the photo to the end of the album you choose. Smart albums aren't listed. If the photo is already in that album, nothing changes. **Add to Album › New Album…** opens a **New Album** window with the note "The photo will be added to it." Type a **Name** and click **Create**. The viewer stays open.
- **Show in Library** takes you back to the library and opens All Media with this photo selected and scrolled into view. If All Media's setting would hide the item, it switches to **Show All**.

This menu isn't offered for videos, or for anything in the Trash. For a video, use **Image › Show in Library** instead, which works for photos too. To add a video to an album, go back to the library, right-click it in the grid and choose **Add Photo to Album**.

## Other Image menu commands

**Image › Move to Folder** works in the viewer too, and moves the item on screen to another folder. The viewer stays open. To undo the move, choose **Edit › Undo Move** (⌘Z). Organizing Files explains moving.

Some menu commands are greyed out while the viewer is open. These include **View › Show All**, **Show Only Photos** and **Show Only Videos**, **Bigger Thumbnails** and **Smaller Thumbnails**, the sort commands and **Shuffle Again**, **Scroll Automatically**, and **File › Duplicate Album** and **Rename Album…**. Go back to the library to use them.

Every keyboard shortcut is listed in the Keyboard Shortcuts chapter.
"""#),
        Chapter(id: "albums", title: "Favorites and Albums", symbol: "rectangle.stack", markdown: #"""
Favorites and albums are two ways to gather photos without moving them. A favorite is a photo you've marked with a heart. An album is a collection you name and fill yourself. Neither one moves, copies or changes a file. The photo stays in its folder, and the same photo can be a favorite and be in any number of albums at once.

Favorites and albums are kept in PhotoVault's catalog, inside the vault, so they go wherever the vault goes. Nothing is written into the photos themselves.

## Favorites

### Marking a favorite

In the library, select one or more photos, then do any of these:

- Press the full stop key (.).
- Choose **Image › Add to Favorites** (.).
- Right-click one of the photos and choose **Add Photo to Favorites**. With several photos selected, it reads **Add 3 Photos to Favorites**, and so on. If you right-click a photo that isn't selected, the command acts on that photo alone.

**Image › Add to Favorites** is greyed out until you select something.

In the viewer:

- Press the full stop key (.), or choose **Image › Add to Favorites** (.).
- Or click the heart in the bar at the top of the viewer. If the bar is hidden, move the pointer to show it. The heart turns red and filled.

In the viewer, these act only on the photo on screen.

Wherever a favorite appears in the library, its thumbnail has a small white heart in the bottom-left corner.

### Removing a favorite

Use the same key and commands. If every photo you've picked is already a favorite, the full stop key takes them all out of Favorites. The menus then read **Image › Remove from Favorites** and **Remove Photo from Favorites** (or **Remove 3 Photos from Favorites**). If only some of them are favorites, the full stop key makes them all favorites.

In the viewer, click the red heart to take the photo out of Favorites.

### The Favorites view

To see every favorite photo and video, click **Favorites** (the heart) in the Library section of the sidebar. Photos in the Trash are left out. Albums show a count beside their names, but Favorites doesn't.

Favorites shares its sort with All Media, your folders and the Trash. Change the sort in one of them and it changes in all of them. Like every view, Favorites keeps its own All, Photos or Videos choice and its own place. See Browsing Your Library.

If you remove a favorite while looking at Favorites, it leaves the grid straight away. In the viewer, the photo stays on screen, but ← and → no longer move on from it. Go back to the library (Esc) and open the next photo from there.

### Good to know

- While you're typing in a box, such as an album's name, the full stop key types a full stop.
- In the Trash, the full stop key does nothing and **Image › Add to Favorites** is greyed out.
- A favorite you move to the Trash keeps its heart. If you put it back, it's in Favorites again.

## Albums

An album holds whatever photos and videos you put in it, in the order you added them. A photo can be in as many albums as you like. Albums are listed under **Albums** in the sidebar. That heading appears once you make your first album. The number beside an album is how many photos and videos it holds.

Smart albums, which choose their own photos by their tags, are covered in Smart Albums and Automatic Tags. You rename, duplicate, reorder and delete them the same way as albums, as described below.

### Making an album

Start a new album in any of these ways:

- Choose **File › New Album…** (⌘N).
- Click **New Album** (+) at the bottom of the sidebar.
- Right-click photos in the grid and choose **Add Photo to Album › New Album…** (with several selected, **Add 3 Photos to Album › New Album…**).
- In the viewer, right-click a photo and choose **Add to Album › New Album…**. This menu appears for photos, not videos.

A **New Album** window opens. Type a name in the **Name** box, then click **Create** (↩) or **Cancel** (Esc).

A line of small text says what will go in:

- "Creates an empty album." when nothing is selected in the grid.
- "The 3 selected item(s) will be added." when photos are selected in the grid. They go into the new album as soon as you click **Create**.
- "The photo will be added to it." or "The 5 photos will be added to it." when you started from Add to Album.

When you start from **File › New Album…** or the + button, the window also has a **Smart album** checkbox. Leave it unticked for an ordinary album. **File › New Smart Album…** (⌥⌘N) opens the same window with the box already ticked, so untick it if you want an ordinary album. The window you get from Add to Album has no checkbox. It always makes an ordinary album.

The new album goes at the bottom of the Albums list. PhotoVault stays on the view you were in, so you can keep picking photos. To open the album, click it in the sidebar.

**Create** stays greyed out until you type a name. Spaces at the start and end of a name are dropped. PhotoVault lets two albums have the same name, so choose names you can tell apart.

### Adding photos to an album

- **Right-click.** Select the photos, right-click one of them and choose **Add 3 Photos to Album**, then the album's name. Right-click a photo that isn't selected to add just that one. The menu says "Photo" even for videos.
- **Drag.** Drag photos from the grid onto an album in the sidebar. The album's row lights up, and the photos are added when you let go. If you drag a selected photo, the rest of the selection comes too. The status line then says, for example, "Added 3 items to Holidays".
- **In the viewer.** Right-click the photo and choose **Add to Album**, then the album's name. This menu only appears for photos, so add videos from the grid.

These menus list albums only, never smart albums, and you can't drop photos on a smart album. Adding to an album has no keyboard shortcut.

New photos go at the end of the album's order. If a photo is already in the album, adding it again does nothing and it stays where it was.

Photos in the Trash can't be added to an album. In the Trash, the right-click menu has no Add to Album, dragging photos onto an album does nothing, and the viewer has no Add to Album menu for them.

Watch where you drop. Dropping photos on an album adds them to it. Dropping them on a folder moves the files into that folder, and dropping them on All Media moves the files to the top of the Photos folder. See Organizing Files.

### Removing photos from an album

Open the album and select the photos. Right-click one of them and choose **Remove Photo from This Album** or **Remove 3 Photos from This Album**. They're removed at once, without a question. The photos stay in the library, in their folders, in Favorites and in any other albums.

To put a photo back, add it again. It goes to the end of the album's order. Album changes can't be undone: **Edit › Undo Move** (⌘Z) only undoes moving photos to a folder.

**Move to Trash (⌘⌫) does something different.** It takes the photo out of the library and out of every album it was in. **Put Back** brings the photo back, still a favorite if it was one, but not into its albums.

### Album order and sorting

Each album has its own sort, chosen from the **Sort** menu at the top of the grid. As well as the usual Date Taken, Date Created, File Name, Length and Random, albums offer **Album Order**. See Browsing Your Library for what each sort does.

**Album Order** is the order the photos were added. A new album starts in Album Order, Oldest first, so the first photo you added comes first. To switch to Newest first, click the arrow button beside **Sort**. Or choose **View › Newest first** (⌥⌘↓), and **View › Oldest first** (⌥⌘↑) to switch back.

Each album remembers its own sort, its own All, Photos or Videos choice and its own place. Changing these never affects the library or another album.

You can't drag photos into a different order inside an album. If the order matters, add the photos one at a time in the order you want. Or choose another sort, such as Date Taken or File Name.

### Seeing which albums a photo is in

Open the photo in the viewer and choose **Image › Show Properties** (⌘I), or click the info button at the right of the bar at the top. The panel's Library section shows **Favorite** (Yes or No) and **Albums**, which lists the albums the photo is in, or None.

### Renaming an album

- Click the album in the sidebar, then press ↩ (Return), as in Finder.
- Or, with the album showing, choose **File › Rename Album…**.
- Or right-click the album in the sidebar and choose **Rename…**.

The **Rename Album** window opens with the current name filled in. Change the name and click **Rename** (↩), or click **Cancel** (Esc). The name can't be left blank.

### Duplicating an album

With the album showing, choose **File › Duplicate Album** (⌘D). Or right-click the album in the sidebar and choose **Duplicate Album**.

If the album is called Holidays, the copy is called "Holidays (copy)". If that name is taken, it's "Holidays (copy 2)", and so on. The copy has the same photos in the same Album Order, and the same sort. It appears just below the original, and PhotoVault switches to it.

No photos are copied. Both albums simply list the same photos. That makes a duplicate a safe way to try out a different selection: removing photos from the copy leaves the original as it was.

**File › Duplicate Album** and **File › Rename Album…** are greyed out unless an album is showing in the grid. They're also greyed out while a photo is open in the viewer.

### Putting albums in order

Drag an album up or down in the Albums list. A thin line in the accent color shows where it will land. Let go to drop it there. The order is saved in the vault.

Smart albums are reordered the same way, among themselves. You can't drag an album into the Smart Albums list, or a smart album into the Albums list.

### Deleting albums

To delete one album, right-click it in the sidebar and choose **Delete Album**. It's deleted straight away. PhotoVault doesn't ask first, and you can't undo it.

To delete several at once:

1. Click one album in the sidebar.
2. ⌘-click the others, or ⇧-click to pick a run of them. While several are picked, the grid keeps showing what it was showing.
3. Right-click one of them and choose **Delete 3 Albums…**. The number matches how many you picked.
4. PhotoVault asks "Delete 3 Albums?" and says "Their photos stay in the library — only the albums go." Click **Delete** or **Cancel**.

You can pick albums and smart albums together. The menu then reads, for example, **Delete 1 Album and 1 Smart Album…**. Other picked rows, such as All Media or a folder, aren't affected.

No key deletes an album. ⌘⌫ is Move to Trash, which acts on photos, never on albums.

### What deleting an album does to its photos

Nothing. Only the album is deleted, along with its order, its sort and its remembered place. Its photos stay in All Media, in their folders, in Favorites and in any other albums. Their files aren't touched.

If you were looking at the album when you deleted it, PhotoVault switches to All Media.

### An empty album

An empty album shows "Nothing here yet", and so does Favorites when you have no favorites. The hint underneath, about dropping files into the Photos folder, is about adding photos to the vault. To fill an album, add photos as described above.

## Export Albums & Favorites

**Vault › Export Albums & Favorites…** saves a record of your favorites and all your albums in a file called memberships.json. The file goes in the vault's hidden .catalog folder.

No window opens. The file is saved straight away. The status line at the top of the grid then says "Exported to .catalog/memberships.json". If photos are selected, the status line shows how many are selected instead. Each export replaces the file from the last one.

### What's in the file

- Every favorite.
- Every album's name and its photos. The albums are in the same order as in the sidebar.

The file doesn't use file names or folders to say which photos these are. Instead, each photo is recorded by a fingerprint taken from its contents. So the file still matches a photo after it has been renamed or moved, or when it's in another copy of the vault.

The file doesn't keep an album's Album Order or its sort. Each album's photos are listed by date taken. Smart albums aren't included, because they choose their own photos. Photos in the Trash aren't included either.

### Why it's there

The export is a safety record for when copies of a vault drift apart. Say you keep a copy on a second drive, and over time you make albums in both copies. The file names each photo by its contents, not by where it is, so it can be checked against the photos in the other copy.

PhotoVault has no command to read the file back in. Exporting doesn't change your albums, your favorites or your photos.

If the file can't be saved, for example because the vault is read-only, an alert titled "PhotoVault" says why.

To look at the file, open the vault in Finder and press ⇧⌘. (Shift, Command and the full stop key) to show hidden files. Then open the .catalog folder. Don't change anything else in .catalog.
"""#),
        Chapter(id: "tags", title: "Smart Albums and Automatic Tags", symbol: "tag", markdown: #"""
PhotoVault can tag your photos, which means giving each one short words that say what's in it. Smart albums then use those tags to choose their photos. You tell a smart album which tags to look for, and it keeps itself up to date.

## Automatic tags with JoyTag

### What JoyTag does

JoyTag is a tagging model. The PhotoVault installer puts it on your vault, unless you choose to leave it out. It looks at each photo and names what it sees, with tags such as "dog", "beach", "sunset", "smile" or "blonde hair". It knows almost 6,000 tags, covering people, clothes, animals, places, food, weather, colors, styles and much more. Some tags count the people in a picture, such as "1girl" or "2boys".

- JoyTag runs on your Mac. Nothing is sent over the internet, and it works without a connection.
- It looks at the thumbnail PhotoVault already keeps for each photo, not at the original file. Videos get tagged too, from their thumbnail picture.
- Its tags are kept in the vault's catalog, along with your albums and favorites. They go with the vault to any Mac.
- Tagging never changes your photos. Nothing is written into the files.

JoyTag is good but not perfect. Sometimes it misses something, or names something that isn't there. Think of its tags as a helpful guess.

### When tagging happens

Each time PhotoVault opens, it checks the vault for changes. When that check finishes, PhotoVault looks for photos JoyTag hasn't tagged yet. It looks again after Vault › Rescan Changed Folders (⌥⌘R) and Vault › Full Rescan (⌥⇧⌘R).

- If there are 100 photos or fewer to tag, tagging starts straight away, without asking.
- If there are more, PhotoVault asks first.
- If you stop the check before it finishes, PhotoVault doesn't look for untagged photos that time.

This means new photos you copy into the Photos folder get tagged the next time PhotoVault opens or rescans. A photo can only be tagged once its thumbnail has been made. Photos in the Trash are not tagged.

### The question before a large run

When there are more than 100 photos to tag, PhotoVault asks first, for example "Tag 1,234 photos with JoyTag?". The message says the photos themselves aren't changed, and gives a rough time, such as "about 20 minutes".

- Click **Tag Photos** to start.
- Click **Not Now** to leave it for now. Until PhotoVault next opens, it won't ask again or tag new photos by itself, even after a rescan. You can still start at any time with Image › Classifier › Tag Untagged Photos.

At first the time is only a rough guess. After a run of 20 photos or more, PhotoVault remembers how fast your Mac was and uses that for later guesses.

### While tagging runs

Tagging runs in the background, so you can keep browsing and viewing photos. The status line in the toolbar first says "Loading JoyTag…". Then it shows progress, such as "Tagging with JoyTag — 120 of 1,234", with a progress bar. A **Tag faster** checkbox sits to its left, and a **Stop** button to its right.

- Tick **Tag faster** to finish sooner. JoyTag then works on two photos at once, at a higher priority, so the Mac gets busier. You can tick or untick it while tagging runs. It starts unticked on every new run.
- You can't rescan, move photos to another folder or use Vault › Fix Permissions… while tagging runs. Those commands stay greyed out until tagging finishes or you stop it.
- JoyTag uses about 400 MB of memory while it works. It frees that memory when the run ends.

When the run finishes, the status line gives the total, for example "Tagged 120 photos with JoyTag". Smart albums and the tag lists in the filter panel are then brought up to date. If some photos couldn't be tagged, an alert lists up to five of them, each with the reason.

### Stopping, and carrying on next time

To stop tagging, click **Stop** in the toolbar or choose Vault › Stop Tagging (⌘.). Each photo's tags are saved as soon as that photo is done, so stopping loses nothing.

The status line then says "Tagging stopped — it carries on next time PhotoVault opens". The next time PhotoVault opens, it offers to tag the rest, and asks first if more than 100 are left. To carry on sooner, choose Image › Classifier › Tag Untagged Photos.

If you quit while PhotoVault is tagging, it asks first, under the title "PhotoVault is still tagging photos". Click **Stop and Quit** to stop, or **Keep Tagging** to carry on. Vault › Eject Volume (⌘E) asks the same question, with a **Stop and Eject** button. When the Mac logs out, restarts or shuts down, PhotoVault doesn't ask. It stops tagging and carries on next time.

### The Classifier menu

The tagging commands are in Image › Classifier:

- **Re-classify Selection With › JoyTag** tags the selected photos again. In the viewer, it tags the photo on screen again. See "Re-tagging photos" below.
- **Tag Untagged Photos** tags every photo JoyTag hasn't tagged yet. If there's nothing to tag, nothing starts, and the status line says "Every photo is tagged".
- **Show R18 Tags** shows or hides the tags in the R18 group. See "R18 tags" below.

Both tagging commands are greyed out while a scan, a move or a tagging run is going. If tagging can't work on this Mac or this vault, a greyed-out line at the bottom of the menu says why. See "When tagging isn't available" below.

### Re-tagging photos

JoyTag tags each photo once. It doesn't tag a photo again by itself, even after PhotoVault is updated. To make it look again, re-tag the photo. For example, you might re-tag a photo after rotating it, if it was on its side when it was first tagged.

To re-tag photos:

- In the library, select the photos, right-click one of them and choose **Re-tag with JoyTag**. With several selected, the item reads, for example, **Re-tag 5 Photos with JoyTag**. If you right-click a photo that isn't selected, only that photo is re-tagged.
- Or choose Image › Classifier › Re-classify Selection With › JoyTag. In the viewer, this re-tags the photo on screen.

Re-tagging replaces only JoyTag's own tags on those photos. Keywords already in the photos stay as they are. For more than 100 photos, PhotoVault asks first, for example "Re-tag 250 photos with JoyTag?", with the buttons **Re-tag Photos** and **Not Now**. For 100 photos or fewer, re-tagging starts straight away. When it's done, the status line says, for example, "Re-tagged 5 photos with JoyTag". If none of the photos can be re-tagged yet, because their thumbnails haven't been made, it says "Nothing to re-tag".

You stop re-tagging the same way you stop tagging, but a stopped re-tag doesn't carry on later. The status line says "Re-tagging stopped". The photos already done keep their new tags, and the rest keep their old ones. If you quit or eject while re-tagging, the question's title is "PhotoVault is still re-tagging photos".

Re-tagging isn't available in the Trash or for a photo in the Trash. It also isn't available while a scan, a move or a tagging run is going.

### Seeing a photo's tags

Open a photo in the viewer and choose Image › Show Properties (⌘I). The Tags section at the bottom of the panel lists the photo's tags, grouped by where they came from:

- **JoyTag**, with the JoyTag version and the date the photo was tagged.
- Tags from another tagging tool, under that tool's name, if the tool marked them as its own.
- **Keywords already in the photo**, which are keywords another app saved in the file.

If a photo has no tags, the section says "No tags.". Underscores in tag names appear as spaces. You can't add, change or remove tags in PhotoVault. Tags are for finding photos, using smart albums. The panel itself is covered in "Viewing Photos and Videos".

### When tagging isn't available

Tagging needs macOS 15 or later, and JoyTag has to be installed on the vault. If either is missing, Image › Classifier shows the reason in a greyed-out line, and the tagging commands are greyed out.

- **"JoyTag needs macOS 15 or later."** PhotoVault itself runs on macOS 14, but JoyTag doesn't. Everything else still works, including smart albums. They can use keywords already in your photos, and tags made when the vault was open on a Mac with macOS 15 or later.
- **"Photo tagging isn't installed on this vault. To add it, open PhotoVault Installer and install on this vault with Photo tagging ticked."** Tagging was left out when PhotoVault was installed, to save space. To add it, open PhotoVault Installer, choose **Install on an Existing Vault** and pick this vault. Make sure **Include photo tagging (JoyTag)** is ticked (it is unless you untick it). Then click the button at the bottom, which says **Install**, **Update**, **Reinstall** or **Install Older Version**, depending on the PhotoVault already on the vault. JoyTag takes about 370 MB on the vault. If PhotoVault is open from the vault, the installer quits it for you.
- Other messages here, such as "JoyTag's model is missing from this vault.", mean JoyTag's files on the vault are incomplete or can't be read. Installing again with **Include photo tagging (JoyTag)** ticked puts back any missing files.

To take tagging off a vault, install again with that box unticked. This frees the space JoyTag used. The tags JoyTag already made are kept, and smart albums that use them still work.

## Smart albums

A smart album chooses its own photos. You pick tags to include or leave out, and the album shows every photo that matches. When photos are added, tagged or re-tagged, the album changes to match.

You can't add or remove a smart album's photos by hand. Smart albums aren't listed under Add to Album, and you can't drop photos onto them.

Smart albums are listed in the sidebar under **Smart Albums**, each with a filter icon. They have no count beside the name. Photos in the Trash never appear in a smart album. Videos can match too, because JoyTag tags them as well.

### Making a smart album

1. Choose File › New Smart Album… (⌥⌘N). Or choose File › New Album… (⌘N), or click **New Album** at the bottom of the sidebar, then tick the **Smart album** checkbox.
2. Type a name.
3. Click **Create** (↩).

With **Smart album** ticked, the note in the window reads "Chooses its own photos from tag rules, which you set next."

PhotoVault opens the new smart album with its filter panel showing. Until you choose some tags, it shows every photo in the vault. Photos selected in the grid are not added, because a smart album picks its own.

### The filter panel

The filter panel sits between the toolbar and the grid. The grid below shows the matching photos, and it changes a moment after each click.

- To open the panel, click **Edit Filter** in the toolbar. You can also right-click the smart album in the sidebar and choose **Edit Filter…**. When nothing matches and the panel is closed, the grid says "No photos match this filter" and shows an **Edit Filter** button.
- To close it, click **Done**. Your changes are saved as you go. The panel also closes when you go to a view that isn't a smart album. If you pick another smart album instead, the panel stays open and shows that album's filter.
- To rename the smart album, use the name field at the top of the panel. Type the new name, then press ↩ or click **Done**.

The panel has two columns. The left column has the tags you can choose from. The right column, under **In this filter**, shows what you have chosen. If no photo has any tags yet, the panel says "No photo in this vault has tags yet."

### Including and excluding

Click a tag once to include it, a second time to exclude it, and a third time to clear it. A reminder of this sits at the top of the panel.

- An included tag turns green and shows a "+". The album shows only photos that have it.
- An excluded tag turns red, shows a "−" and is struck through. The album leaves out photos that have it.
- The number on each tag is how many photos have it.

Groups work the same way. Click a group's name, not the arrow beside it, to include or exclude the whole group as one item:

- An included group matches a photo that has any tag in that group. It's listed as, for example, "Animals (any tag)".
- An excluded group leaves out every photo that has any tag in that group. It's listed as, for example, "Animals (whole group)".

If you only exclude things, the album starts with every photo and leaves out the ones that match.

### All or Any

The two switches under **In this filter**, labelled **Include** and **Exclude**, decide how your choices combine.

- **Include: All** is the usual setting. A photo needs every tag and group you included, so each choice narrows the album.
- **Include: Any** means one included tag or group is enough, so each choice widens the album.
- **Exclude: Any** is the usual setting. One excluded tag or group is enough to leave a photo out.
- **Exclude: All** leaves a photo out only if it has every tag and group you excluded.

For example, include "dog" and "beach" with **All** to see dogs on the beach. Switch to **Any** to see every dog photo and every beach photo.

**Reset**, under the switches, clears every choice at once, without asking. It also sets the switches back to **Include: All** and **Exclude: Any**, and the album shows every photo again.

The count at the bottom says how many photos match, such as "42 photos match". It follows the All, Photos and Videos switch in the toolbar, and it counts videos as photos.

### Finding tags

A vault can have thousands of tags, so the left column keeps them tidy:

- **Most used**, at the top, shows the 12 tags found on the most photos. It's hidden while you search.
- Below it are the **groups**, such as People, Animals, Places, and Food and drink. They all start closed. Click the arrow beside a group to open it, and click again to close it. Beside each group, for example "57 tags", is how many of its tags are on your photos.
- An open group shows its 12 most used tags first. If it has more, click the link below them, such as **Show all 57**, to see the rest, and **Show fewer** to go back.
- **Other** always comes last. It holds the tags that aren't listed in any group, including most keywords added in other apps.
- Groups with no tags in this vault aren't shown.

The groups come from a file in the vault that you can edit. See "Tag groups" below.

### Searching for a tag

To find a tag, type in the search box at the top of the left column. The box shows how many tags there are to search.

- Capitals don't matter, and a space matches an underscore.
- Any part of a tag's name matches, so "hair" finds "blonde hair" and "long hair".
- Only the groups with a match are shown, and they open by themselves. Each group shows up to 40 matches, with a **Show all** link for the rest.
- Rare tags are included in a search.
- If nothing matches, the panel says so.

Clicking a tag in the results includes or excludes it as usual. Your choices stay under **In this filter** when you clear the search.

### Rare and hidden tags

A tag on fewer than 3 photos counts as *rare*. Rare tags are left out of the group lists. Each open group says how many it is leaving out, such as "4 rare tags hidden". To see them, tick **Show rare tags (on fewer than 3 photos)** at the bottom of the left column. The checkbox is there while the search box is empty.

You can also hide a tag you never want to see, such as one JoyTag keeps getting wrong on your photos. Right-click the tag and choose **Hide Tag**. Nothing is deleted:

- The tag leaves the Most used row, the group lists and search results.
- Its photos aren't touched, and the tag still shows in a photo's properties.
- A link at the bottom of the left column, such as **Show 2 hidden tags**, lists your hidden tags while the search box is empty. Click **Hide the hidden tags** to put the list away again. You can still click hidden tags to include or exclude them. To bring one back, right-click it and choose **Show Tag**.

The vault remembers which tags are hidden.

### What "In this filter" means

The right column lists every tag and group you have included or excluded, in the order you chose them. The list stays the same whatever is in the search box, so you can search for one tag after another and still see everything you've chosen. Clicking an item here works as in the left column: include, exclude, then clear.

### Renaming, copying and deleting smart albums

Right-click a smart album in the sidebar to find **Edit Filter…**, **Rename…**, **Duplicate Smart Album** (⌘D) and **Delete Smart Album**. While a smart album is showing, the File menu also has Duplicate Smart Album (⌘D) and Rename Smart Album….

- To rename, you can also pick the smart album in the sidebar and press ↩. Type the new name and click **Rename**.
- **Duplicate Smart Album** makes a copy with the same tag choices and sort order, and a name such as "Dogs (copy)". Use it to try out a variation without changing the original.
- **Delete Smart Album** deletes the smart album straight away, without asking. Only the smart album goes. Your photos are never deleted.
- To delete several at once, ⌘-click or ⇧-click them in the sidebar, right-click and choose, for example, **Delete 2 Smart Albums…**. PhotoVault asks first. Click **Delete** to go ahead.

To reorder smart albums, drag them up or down in the sidebar. Each smart album keeps its own sort order, as described in "Browsing Your Library". More about albums is in "Favorites and Albums".

## Tag groups

Tag groups decide which group each tag is listed under in the filter panel. PhotoVault comes with 29 groups that sort every one of JoyTag's tags. They are People, Faces, Hair, Body, Clothing, Shoes and socks, Hats and headwear, Accessories, Poses and actions, Animals, Plants and flowers, Food and drink, Places, Nature and outdoors, Sky and weather, Vehicles, Home and furniture, Things, Music, Sports and games, Occasions, Weapons and military, Text and symbols, Colors and patterns, Photo style, Art and illustration, Anime and games, Fantasy and sci-fi, and R18.

You can change these groups, add your own, and put your own keywords in them. Groups also affect which photos match. When a smart album includes or excludes a group, the tags listed in that group decide which photos match. If you change a group, every smart album that uses it changes too.

### Where the file is

The groups are kept in a plain text file called `.Tag Groups.txt`. It's at the top of the vault, next to PhotoVault.app, the Photos folder and README.txt. Its name starts with a full stop, so Finder hides it.

To see the file, open the top of the vault in Finder and press ⇧⌘. (Shift, Command and the full stop key). Hidden files appear, dimmed. Press the same keys again to hide them.

On a vault made with an early version of PhotoVault, the file may be called `Tag Groups.txt`, without the full stop, and isn't hidden. PhotoVault reads it just the same. The installer renames it to `.Tag Groups.txt` the next time you install on that vault.

Open the file in TextEdit or any other text editor, and keep it as plain text.

### How the file works

- A name in square brackets on its own line, such as `[Pets]`, starts a group. Groups appear in the filter in the same order as in the file.
- Each line after that is one tag in the group, such as `dog` or `cat`. Tag lines before the first group are ignored.
- PhotoVault ignores blank lines and lines that start with `#`, so you can use `#` lines for notes.
- Write each tag the way PhotoVault shows it in the filter panel. Capitals don't matter, and a space and an underscore count as the same.
- A tag can be listed in more than one group. It then shows in each of them.
- A tag that isn't listed in any group shows under **Other**, which always comes last.
- Two groups with exactly the same name, capitals included, count as one group.
- You can list your own keywords too. A tag goes under its group whichever app or tool wrote it.

For example, to make a group for your pets, add `[Pets]`, `dog` and `cat` at the end of the file, each on its own line. Dog and cat then show under both Animals and Pets.

### When your changes take effect

PhotoVault reads the file when it opens, and again after each scan, rescan or tagging run, and when you hide or show a tag. After saving your changes, choose Vault › Rescan Changed Folders (⌥⌘R), or quit PhotoVault and open it again.

- If the file is missing or can't be read, PhotoVault uses its own built-in groups. To go back to the built-in groups, delete the file or move it out of the vault.
- Updating PhotoVault with the installer keeps your file as it is. New groups in a later version don't replace your changes. If the file is missing, the installer puts in a fresh copy.

## Keywords already in your photos

Some photo apps save keywords inside the photo file. PhotoVault reads these keywords when it scans, and the status line says "Reading tags" while it does.

- Keywords show in a photo's properties, under **Keywords already in the photo**.
- In the filter panel, keywords and JoyTag's tags form one list. A keyword "Beach" and JoyTag's "beach" count as the same tag, and a smart album that includes it finds photos with either.
- Keywords that aren't listed in any tag group show under **Other**. To give a keyword a group, add it to the tag groups file.
- PhotoVault never changes, adds or removes keywords. It only reads them.
- Keywords are read from photos only, not from videos.

If you change a photo's keywords in another app, PhotoVault reads them again at the next scan that notices the file has changed. If the new keywords don't appear after Vault › Rescan Changed Folders (⌥⌘R), choose Vault › Full Rescan (⌥⇧⌘R).

## R18 tags

The **R18** group holds nude and explicit tags, covering things such as nudity, sex and graphic gore. These tags stay hidden unless you choose to see them with Image › Classifier › Show R18 Tags.

While Show R18 Tags is unticked:

- Tags in the R18 group don't appear in a photo's properties, and nothing says that any were left out.
- They don't appear in the filter panel's Most used row, its group lists or its search, and the R18 group itself isn't listed.
- A tag listed in R18 and in another group is hidden everywhere.

Only tags are hidden, never photos. Photos with R18 tags still appear in All Media, in their folders and in albums. Smart albums that use R18 tags still find their photos, and those choices still show under **In this filter**.

Tick Show R18 Tags to see these tags. The vault remembers your choice. Until you choose, the setting is off, unless a smart album in the vault already uses an R18 tag or the R18 group. It works whether or not JoyTag is installed, so it also hides keywords listed in R18.

JoyTag sometimes misreads a photo, so an innocent photo can end up with an R18 tag. The tag groups file decides which tags are hidden: move a tag into or out of the `[R18]` group to change it. The group must be named exactly R18. If the file has no R18 group, nothing is hidden.
"""#),
        Chapter(id: "files", title: "Organizing Files", symbol: "folder", markdown: #"""
Your photos and videos live in folders inside the vault's Photos folder. PhotoVault can move them from one folder to another, rotate photos, and clear out the ones you no longer want. Everything in this chapter works for videos as well as photos, unless it says otherwise.

## Moving photos into folders

### Dragging onto a folder

1. Select the photos in the library.
2. Drag them onto a folder in the sidebar. The folder's row lights up while the photos are over it.
3. Let go. The photos move into that folder.

- Drop them on **All Media** to move them to the top level of the Photos folder.
- If you drag a photo that is part of a selection, the whole selection goes with it. Otherwise only that photo goes.
- Dropping photos on an album adds them to the album instead. The files stay where they are. See Favorites and Albums.
- You can't drag photos out of the Trash.
- A drag only works inside PhotoVault. Dropping photos on Finder or another app does nothing, so nothing gets copied off the vault by accident.

### Using the Move to Folder menu

**Image › Move to Folder** moves the selected photos. In the viewer it moves the photo on screen, and the viewer stays open.

You can also right-click a photo in the library and choose **Move Photo to Folder** (or **Move 3 Photos to Folder**, and so on). If the photo you right-click is part of a selection, the whole selection moves. Otherwise only that photo moves.

The menu lists:

- **New Folder…**, to make a new folder and move the photos into it.
- **Photos (top level)**, the top of the Photos folder.
- Every folder, nested the same way as in the sidebar. A folder with other folders inside it opens into its own menu. Choose **Move Here** at the top of that menu to move the photos into the folder itself, or pick one of the folders inside it.

**Image › Move to Folder** is greyed out when nothing is selected and when you're looking at the Trash. The right-click menu doesn't offer Move to Folder in the Trash. Both are greyed out while a scan, a tagging run or another move is going on.

### Making a new folder

The sidebar only shows folders that have photos in them, or in folders inside them. An empty folder never appears there. That's why you make a new folder at the moment you move photos into it.

1. Choose **New Folder…** at the top of a Move to Folder menu.
2. Type a name in the **Name** box.
3. Use the **In** menu to choose where the new folder goes: **Photos (top level)**, or any folder. Inside a folder's menu, pick **Choose This Folder** to put the new folder there. The menu starts at the folder the photos are already in, if they are all in one folder. Otherwise it starts at the top of the Photos folder.
4. Click **Create and Move** (↩). Click **Cancel** (Esc) to leave everything as it was.

**Create and Move** stays greyed out until the name is allowed. A folder name can't be blank, can't start with a full stop, and can't contain "/" or ":". A name that starts with a full stop is hidden on a Mac, and PhotoVault skips hidden files and folders. If a folder with that name is already there, PhotoVault doesn't warn you. The photos just go into that folder.

### What moving does

- Each file moves on the disk, from one folder of the vault to another. It's quick and uses no extra space.
- A moved photo keeps its favorite, its albums, its tags and its thumbnail. Nothing needs to be scanned or tagged again.
- Moving never overwrites a file. If the folder already has a file with the same name, the moved file gets a new name, as in Finder: "name 2.jpg", then "name 3.jpg", and so on.
- Photos in the Trash and missing photos aren't moved.
- If a move leaves a folder empty, the folder disappears from the sidebar but stays on the disk. You can delete it in Finder if you like.

When the move is done, the status line at the top of the library says "Moved 12 items to" followed by the folder's name. The top level is called "Photos". If the photos were already in that folder, the status line says so instead.

These messages only show while nothing is selected. Photos that are still in view stay selected after a move, so you may see "12 selected" until you click an empty part of the grid.

### Progress and Stop

While photos move, the status line shows how far it has got, for example "Moving — 250 of 1,200", with a progress bar and a **Stop** button. **Vault › Stop Moving** (⌘.) does the same thing as Stop.

If you stop a move, the photos already moved stay in their new folder and the rest stay where they were. The status line says "Moving stopped — the photos moved so far are in their new folder".

PhotoVault does one job at a time. While a scan, a tagging run or a move is going on, the Move to Folder menus are greyed out, and dropping photos on a folder does nothing. Wait for the job to finish, or stop it, then try again.

### Undo Move

**Edit › Undo Move** (⌘Z) puts back the photos from the last move. Each one goes back to its old folder under its old name. If another file has that name by now, the photo gets a number, as in "name 2.jpg". The status line says, for example, "Moved 12 items back".

- Undo Move only covers the last move, and only once. There's no Redo for moves.
- A move you stopped can't be undone. Move those photos back yourself.
- PhotoVault forgets the last move when it quits or when the vault is ejected.
- Photos that went to the Trash, or went missing, after the move stay where they are.
- When there is nothing to undo, the menu item just reads **Undo**.
- While a scan, a tagging run or another move is going on, Undo Move does nothing. Try again once the job has finished.
- While you're typing in a box, ⌘Z undoes your typing instead.

### Moving and renaming in Finder

You can also arrange the Photos folder in Finder. You can make folders, rename them, and move folders and files around inside Photos, and PhotoVault keeps up. The next time it looks, it finds each photo in its new place by checking what's inside the file. It looks each time it opens, or when you choose **Vault › Rescan Changed Folders** (⌥⌘R). Each photo keeps its favorite, its albums and its tags.

PhotoVault only shows what is inside the Photos folder. A file you move out of that folder becomes missing in PhotoVault (see Missing files, below). When you browse the vault in Finder, use list or column view. Your Vault explains why.

## Rotating photos

**Rotate Left** (⌘L) and **Rotate Right** (⌘R) turn a photo a quarter turn. You'll find them in the Image menu, in a photo's right-click menu, and as buttons on the viewer's top bar. In the library they act on the selected photos. In the viewer they act on the photo on screen.

Only JPEG photos (.jpg or .jpeg) can be rotated. PNG, HEIC, TIFF, GIF, BMP and WebP photos can't, and neither can videos. The rotate commands are greyed out for them, and for photos in the Trash. If your selection mixes JPEGs with other files, only the JPEGs turn.

How rotating works:

- PhotoVault changes only the photo's orientation. That is a small setting inside the file that tells apps which way up to show the picture. The picture itself is never saved again, so it loses no quality.
- Before it replaces anything, PhotoVault checks the result. If anything other than the orientation would change, it stops and leaves the original alone.
- PhotoVault makes a new thumbnail straight away.
- Finder shows the file as modified at the time you rotated it. For some photos, the created date changes too.
- There's no undo. To put a photo back, rotate it the other way.

If a photo can't be rotated, a message says why, for example "the file is read-only." Locked and read-only files can't be rotated. **Vault › Fix Permissions…** can fix that (see below).

## The Trash

### Moving photos to the Trash

**Move to Trash** (⌘⌫) is in the Image menu, in the right-click menu (as **Move Photo to Trash**, or **Move 3 Photos to Trash**), and on the viewer's top bar as a trash can. It doesn't ask first.

Moving a photo to the Trash only marks it. The file stays in its folder on the disk. The photo leaves every view and every album it was in, and it shows under **Trash** in the sidebar. In the library, the status line says, for example, "Moved 3 items to the Trash". In the viewer, the next photo comes up, or the one before it if it was the last.

Take care in an album. ⌘⌫ moves the photo to the Trash. It doesn't just take the photo out of the album. To take a photo out of one album only, see Favorites and Albums.

### Putting photos back

In the Trash, right-click a photo and choose **Put Back Photo** (or **Put Back 3 Photos**). In the viewer, use the **Put Back** button (a curved arrow) on the top bar. There's no keyboard shortcut. In the library, the status line then says, for example, "Put back 3 items".

A photo you put back returns to the library, in the same folder. If it was a favorite, it still is. It doesn't go back into its albums, so you'll need to add it to them again.

### Emptying the Trash

Choose **Vault › Empty Trash…**, or right-click **Trash** in the sidebar and choose **Empty Trash…**. The command is greyed out when the Trash is empty.

First, PhotoVault checks that macOS will let it delete every file. Then it asks "Empty the Trash?" and tells you how many files it will delete for good. If some files can't be deleted as things stand, it tells you how many and why, for example "(2 locked)". It also says it will tell you what you can do about them once the rest are gone.

Click **Empty Trash** to go ahead, or **Cancel**. Empty Trash always deletes everything in the Trash. There's no way to delete only some of it for good, so put back anything you want to keep first.

Emptying the Trash deletes the original files from the vault for good. They don't go to your Mac's own Trash, and you can't get them back. Afterwards the status line says, for example, "Deleted 40 items".

If your vault is a disk image, the disk image doesn't shrink by itself when files are deleted. See Your Vault for how to get the space back.

The Trash count in the sidebar can include photos whose files are already gone. Emptying the Trash clears those too.

### When files can't be deleted or moved

Sometimes macOS won't let PhotoVault delete or move a file. This happens most often with photos copied from another Mac or an old drive. When it does, PhotoVault opens a window that says what went wrong and what you can do about it.

The title says how many files are affected, for example "3 items couldn't be deleted" or "3 items couldn't be moved". If the other files went through, a line under the title says how many did. Files that couldn't be deleted stay in the Trash. Files that couldn't be moved stay where they were.

The window sorts the files into groups by reason. Each group explains the problem and lists up to six file names:

- **The vault is read-only**: the vault's disk image or drive is open read-only, so nothing on it can change. Eject it, then open it again so it can be written to.
- **Locked**: the files are yours and locked, as set in Finder › Get Info › Locked.
- **Locked, and belonging to another user**: the files are locked, and they belong to another user on this Mac or on the Mac they came from.
- **In a folder you can't change**: the folder doesn't let your account add or remove files. When moving, this can also be the folder the photos were going to. This is common for folders copied from another Mac.
- **Belonging to another user**: the folder only lets each file's owner remove it, and these files belong to someone else.
- **Couldn't be changed**: macOS refused for some other reason. The reason is shown beside each file.

After emptying the Trash, the window offers these buttons:

- **Unlock and Delete** (↩): clears Locked on the files that are yours, just as unticking Locked in Finder does, then tries again. It only shows when some of the files are locked and belong to you.
- **Delete with Administrator Password…**: for files that belong to another user, files in a folder you can't change, and files macOS refused for other reasons. macOS asks for an administrator's password in its own window. PhotoVault never sees the password, and macOS asks again every time. While it waits, the status line says "Waiting for an administrator's password…". If you click Cancel in the password window, nothing changes. If some files still can't be deleted, the window comes back with those. If macOS reports a problem, an alert says "The files couldn't be deleted:" or "The files couldn't be moved:" and why.
- **Show in Finder**: shows the files, so you can change their permissions in Finder's Get Info window. Then click Try Again.
- **Try Again**: tries the same files again.
- **Keep in Trash** (Esc): closes the window, and the files stay in the Trash.

After a move, the buttons are **Unlock and Move**, **Move with Administrator Password…**, **Show in Finder**, **Try Again** and **Leave Them** (Esc). A move made with an administrator's password never overwrites a file either. After **Unlock and Move** or **Try Again**, Undo Move only puts back the photos moved on that try.

If the vault is read-only, the window only offers **Show in Finder** and **Keep in Trash** (or **Leave Them**).

## Fix Permissions

Photos copied from another Mac, an old drive or a Time Machine backup sometimes come with settings that stop PhotoVault moving or deleting them. **Vault › Fix Permissions…** finds these settings and fixes them all at once. Try it if moving photos or emptying the Trash runs into locked or read-only files, or after you copy in photos from another Mac or a backup.

PhotoVault checks every file and folder in the Photos folder, and the Photos folder itself. While it checks, the status line says "Checking permissions…". It looks for four kinds of problem:

- **with rules copied from a backup**: Time Machine puts rules on every file in a backup to stop it being changed. Files copied out of a backup keep those rules.
- **locked**: Locked is ticked in Finder's Get Info window.
- **read-only**: not even the file's owner may change it.
- **belonging to another user**: the file belongs to another account, on this Mac or on the Mac it came from.

If all is well, PhotoVault says "Nothing needs fixing": every photo, video and folder in the vault can be moved and deleted. Click **OK**.

Otherwise it asks something like "Fix the permissions of 25 items?" and lists how many of each kind it found. Click **Fix** to go ahead, or **Cancel**. Fixing removes the rules copied from a backup, clears Locked, and lets you change the files. It only changes permissions, never the photos. Afterwards the status line says, for example, "Fixed the permissions of 25 items".

Only an administrator can change files that belong to another user. If any files are left that PhotoVault couldn't fix by itself, it asks again, for example "3 items need an administrator". Click **Use Administrator Password…**, and macOS asks for an administrator's password in its own window. PhotoVault never sees the password. macOS then makes the files yours, unlocks them, lets you change them, and removes every access rule on them. If you click Cancel in the password window, the files stay as they were, and the status line says "Permissions left as they were".

While it fixes, the status line says "Fixing permissions…". If some items still can't be fixed after the administrator's password, it says how many, for example "2 items still couldn't be fixed". If macOS reports a problem, an alert says "The permissions couldn't be fixed:" and why.

**Fix Permissions…** is greyed out while it is already checking or fixing, and while a scan, a tagging run or a move is going on.

## Rescanning

PhotoVault checks the Photos folder for changes every time it opens. Usually it only looks quickly at the folders that changed. The status line says "Checking for changes…", and a Stop button shows for a moment. The first time a vault is opened, or if PhotoVault didn't close properly the last time, it looks through every folder instead, and the status line says "Scanning all folders…".

You can also tell it to look again while it's open:

- **Vault › Rescan Changed Folders** (⌥⌘R) looks in folders whose contents changed, meaning files were added, removed or renamed, and in any new folders. Use it after adding photos or rearranging folders in Finder.
- **Vault › Full Rescan** (⌥⇧⌘R) looks at every file in every folder. It takes longer. Use it after you change a photo in another app and save it in place, because Rescan Changed Folders doesn't notice changes inside a file.

While it scans, the status line shows each step, such as "Building thumbnails — 120 of 800" and "Reading tags — 300 of 800". Both rescan commands are greyed out while a scan, a tagging run or a move is going on. After a scan, PhotoVault may start tagging new photos. See Smart Albums and Automatic Tags.

### Stopping

To stop a scan, click **Stop** in the status line, or choose **Vault › Stop Scan** (⌘.). During a move the same command reads **Stop Moving**, and during tagging it reads **Stop Tagging**.

Stopping a scan loses nothing. PhotoVault keeps the thumbnails it has made so far and picks up the scan the next time it opens, or the next time you rescan. The status line says "Scan stopped — it carries on next time PhotoVault opens".

### Quitting or ejecting in the middle of a job

PhotoVault asks first if you try to quit or eject while a scan, a tagging run or a move is going on. That means quitting with ⌘Q, from the Dock or by closing its last window, or choosing **Vault › Eject Volume** (⌘E). The title says what PhotoVault is doing: "PhotoVault is still scanning", "PhotoVault is still tagging photos", "PhotoVault is still re-tagging photos" or "PhotoVault is still moving photos". The message says how far it has got and what happens if you stop now.

- **Stop and Quit** (or **Stop and Eject**) stops the job, then quits or ejects.
- **Keep Scanning**, **Keep Tagging** or **Keep Moving** closes the question and lets the job carry on.

Stopping here is safe. A scan or a tagging run picks up where it left off the next time PhotoVault opens. When re-tagging, the photos already re-tagged keep their new tags and the rest keep their old ones. In a move, the photos already moved stay in their new folder and the rest stay where they were.

When the Mac logs out, restarts or shuts down, PhotoVault doesn't ask. It stops the job in the same safe way and quits.

## Missing files

If a photo's file disappears from the Photos folder, PhotoVault notices on its next scan, and the photo becomes missing. This happens, for example, if the file is deleted in Finder or moved out of the vault.

- Missing photos are hidden from every view.
- PhotoVault doesn't forget them. A missing photo keeps its favorite, its albums and its tags.
- If the file comes back unchanged, the photo returns with everything it had. The file can come back to its old place or anywhere else in the Photos folder. PhotoVault finds it by checking what's inside the file, at its next scan or when you choose **Vault › Rescan Changed Folders** (⌥⌘R).
- Keep the Photos folder at the top of the vault, named Photos. If it goes missing while PhotoVault is open, a rescan doesn't mark anything as missing. But if PhotoVault opens and can't find a Photos folder, it makes a new, empty one, and every photo becomes missing. Move your folders and files back into Photos, then choose **Vault › Rescan Changed Folders** (⌥⌘R), and they return with everything they had.
"""#),
        Chapter(id: "vault", title: "Your Vault", symbol: "externaldrive", markdown: #"""
A vault is a disk image. It's a single file, on your Mac or on an external drive, and it holds your photos and videos along with PhotoVault itself. Its name ends in .sparsebundle. Double-click it and it opens in Finder as a disk with the vault's name. Then open PhotoVault.app from that disk to see your library. Everything PhotoVault needs is on that disk, so a vault works the same on any Mac you take it to.

## What's inside a vault

At the top of the vault's disk you'll see three things:

- **Photos**: your photos and videos, in whatever folders you like. This is the only folder PhotoVault looks in. Its folders are the ones listed under All Media in the sidebar.
- **PhotoVault.app**: the app. Each vault carries its own copy, and it only works from inside its vault. A copy in your Applications folder can't find any photos. It says "No .catalog folder found alongside the app. Move PhotoVault.app to the top level of the vault."
- **README.txt**: short notes about the vault, kept beside the app.

PhotoVault also keeps a few hidden items at the top of the vault. To see them in Finder, press ⇧⌘ and the full stop key (.). Press the same keys again to hide them.

- **.catalog**: PhotoVault's own folder. See below.
- **.Tag Groups.txt**: the list that sorts tags into groups when you set up a smart album's tag filter. You can edit it; see Smart Albums and Automatic Tags.
- **.metadata_never_index**: an empty file that asks Spotlight not to index the vault, to keep your photos and their names out of Spotlight searches.
- **.VolumeIcon.icns**: the vault's icon in Finder.

### Inside .catalog

- **catalog.sqlite**: the catalog, PhotoVault's record of your library. It holds your albums, smart albums, favorites, the Trash, tags and each photo's details. It also keeps PhotoVault's settings, such as the window's size, sort orders, thumbnail size, slideshow time, and where you were in each view.
- **thumbs.pack**: the thumbnails, the small pictures in the grid. They're made once and kept.
- **models**: JoyTag, the photo-tagging model, in a folder called JoyTag, with its licence. It takes about 370 MB. It's only there if photo tagging was installed.
- **backups**: before a new version of PhotoVault changes the catalog's format, it saves a copy of the catalog as it was. Those copies go in this folder.
- **memberships.json**: a list of your favorites and of the photos in each album. It only appears after you choose Vault › Export Albums & Favorites…. Each export replaces the last one.
- **tmp**: a folder PhotoVault uses for its own work.

### What to leave alone

- **Photos** is yours. Add photos and videos to it, then choose Vault › Rescan Changed Folders (⌥⌘R). PhotoVault also looks for changes each time it opens. You can move and rename files and folders inside Photos in Finder too. After a rescan, PhotoVault recognizes a moved photo by its contents and keeps its favorite, albums and tags. Organizing Files shows how to do the same inside PhotoVault. Don't rename the Photos folder itself: PhotoVault only looks in a folder called Photos at the top of the vault.
- **PhotoVault.app** stays at the top of the vault, beside Photos, under its own name. Updates replace it there.
- **README.txt** is replaced every time PhotoVault is updated, so don't keep your own notes in it.
- **.Tag Groups.txt** can be edited in any text editor. PhotoVault reads it each time it opens. Updates keep your copy. If it's deleted, PhotoVault uses its own built-in list, and the next update puts a fresh copy back.
- **.catalog** should be left alone. Don't open, move, rename or delete anything in it. If it were lost, your photos would stay, but your albums, smart albums, favorites, tags and settings would all be gone.
- **.metadata_never_index** and **.VolumeIcon.icns** should stay where they are. If .metadata_never_index goes missing, PhotoVault puts it back the next time it opens.

## Taking your vault to another Mac or drive

Everything lives inside the disk image, so moving a vault means copying one file. Your albums, favorites, tags, smart albums, settings and your place in each view all go with it. PhotoVault keeps its settings in the vault, not on your Mac. The catalog doesn't record which Mac, drive or user it was on.

### Copying the vault

1. In PhotoVault, choose Vault › Eject Volume (⌘E). PhotoVault quits and the vault's disk is ejected. If PhotoVault is still scanning, tagging or moving photos, it asks first. Click **Stop and Eject**, or keep it going and eject later.
2. In Finder, copy the vault's .sparsebundle to the other drive or Mac, as you would any file.
3. Keep the original until you've opened the copy and seen your photos in it.

Always eject from inside PhotoVault before you copy. A copy made while the vault is open can catch the catalog partway through saving. Ejecting the disk in Finder doesn't work while PhotoVault is open, because PhotoVault runs from that disk. If the disk is still there a moment after PhotoVault quits, wait a little and eject it in Finder.

Don't copy a vault into iCloud Drive, or into a Desktop or Documents folder that iCloud keeps in sync. Every photo in it would be uploaded to iCloud. The installer warns about iCloud Drive when it creates a vault.

A Finder copy includes everything, even space left over from deleted photos (see Disk space below). Terminal can make a tidier copy that leaves that space out. With the vault ejected, type this, with a space at the end:

`hdiutil convert -format UDSB -imagekey sparse-band-size=65536 -o ~/Copy.sparsebundle`

Then drag the vault's .sparsebundle onto the Terminal window and press ↩. Terminal may warn that the command is deprecated. That's expected. The copy appears in your home folder as Copy.sparsebundle. You can rename it and move it wherever you like. A password-protected vault should be copied in Finder instead, because a copy made this way has no password.

### Opening it on another Mac

Double-click the .sparsebundle, then open PhotoVault.app from the disk that appears. PhotoVault needs a Mac with Apple silicon and macOS 14 or later. Photo tagging needs macOS 15 or later. PhotoVault finds its photos wherever macOS opens the disk, so it doesn't matter what the disk is called.

A vault that came by download or AirDrop may be blocked by macOS. It may refuse to open PhotoVault, or run it from a temporary copy somewhere else. PhotoVault then can't find its vault and says "macOS is running this app from a temporary copy, so it can't find the vault." You only need to fix this once:

1. Quit PhotoVault.
2. Open Terminal and type `xattr -dr com.apple.quarantine` followed by a space.
3. Drag PhotoVault.app from the vault's disk onto the Terminal window, and press ↩.
4. Open PhotoVault again.

The vault's README.txt has these steps too. If macOS still won't open PhotoVault, the README has one more command to try. Troubleshooting covers other messages you might see when opening a vault.

### Copies don't stay in step

If you keep a copy of a vault on two Macs, each copy is separate. Photos, albums and favorites you add in one don't appear in the other. Work in one copy, and copy it again when you want the other one up to date.

## Password-protected vaults

PhotoVault Installer can protect a new vault with a password while it creates it. Beside **Password:**, tick **Protect with a password**, then type the password in both boxes. macOS then encrypts the whole disk image.

- macOS asks for the password each time the vault is opened, on this Mac or any other. Without it, nobody can open the vault or see its photos.
- **A forgotten password can't be recovered, and the photos are lost with it.** Keep it somewhere safe, such as a password manager.
- When you open the vault, macOS offers to remember the password in your keychain. That's convenient on your own Mac, but then anyone using your Mac account can open the vault.
- If the password is shorter than 8 characters, the installer warns "A password this short is easy to guess." It doesn't stop you using it, but a longer password is harder to guess.
- The installer only sets a password while it creates a vault. It can't add a password to an existing vault or take one off.
- If you pick a protected vault in the installer while it isn't open, the installer asks for its password. Type it and click **Open**. If it's wrong, the installer says "That password isn't right." It uses the password only to open the vault and doesn't keep it.

## Updating PhotoVault

To put a newer PhotoVault on a vault, use the newer PhotoVault Installer:

1. Open PhotoVault Installer and choose **Install on an Existing Vault**.
2. Pick the vault. Vaults that are open are listed beside **Vault:**. For one that isn't open, click **Choose…** and pick its .sparsebundle. If no vault is open, the installer says "No vault is open", and you can also drag the .sparsebundle onto that box.
3. Look at **Include photo tagging (JoyTag)**. It's ticked to start with, which keeps photo tagging, or adds it to a vault that doesn't have it yet.
4. Click **Update**.
5. When it's done, click **Open PhotoVault**, or **Done** to close the installer.

What to expect:

- The installer quits PhotoVault if it's open from that vault. A scan or tagging run carries on the next time PhotoVault opens, but a move or re-tag stops where it is. So it's best to quit PhotoVault yourself first, with ⌘Q.
- Your photos, albums, favorites, tags and settings stay as they are. The installer checks that nothing in .catalog has changed.
- Your .Tag Groups.txt is kept. A visible Tag Groups.txt from an older version is renamed to .Tag Groups.txt, which hides it. README.txt is replaced with the new version.
- If you untick photo tagging, JoyTag is taken off the vault. That frees about 370 MB inside the vault, but the .sparsebundle itself doesn't get smaller until you compact it (see Disk space). Tags it has already made are kept, and smart albums that use them still work. To bring tagging back, install again with the box ticked.
- The button reads **Reinstall** if the vault already has this version, and **Install** if it has no PhotoVault yet.
- If the vault has a newer PhotoVault than the installer, the button reads **Install Older Version**, and a warning says the older version will go in its place. It doesn't ask again before installing, so only click it if you mean to.
- The first time a new version opens a vault, it may update the catalog's format. If it does, it first saves a copy of the old catalog in the backups folder inside .catalog.

## Disk space

You choose a vault's size when the installer creates it: 50 GB, 100 GB, 250 GB, 500 GB, 1 TB or 2 TB. It starts at 500 GB. That size is the most the vault can hold, not the space it takes. The disk image only takes the space its contents use, and grows as you add more. It can only grow as far as the drive it's saved on has room.

The disk image doesn't shrink by itself. When photos are deleted, with Vault › Empty Trash… or in Finder, the vault gets more free room inside, but the .sparsebundle on your drive stays the same size. To get that space back:

1. Choose Vault › Eject Volume (⌘E).
2. If your Mac is a laptop, plug it in. Compacting doesn't run on battery power.
3. Open Terminal and type `hdiutil compact` followed by a space.
4. Drag the vault's .sparsebundle onto the Terminal window, and press ↩.
5. When it's finished, open the vault as usual.

If the vault has a password, you may be asked for it.

Moving photos between folders in PhotoVault doesn't make the vault any bigger.

## Privacy

PhotoVault is built to keep your photos on the vault. One Finder habit can still leave small copies of them on your Mac.

### Finder's icon and gallery views

**Don't browse the Photos folder in Finder's icon view or gallery view.** These views ask macOS's Quick Look for a small picture of each photo. Quick Look keeps those pictures in a shared cache on your Mac, outside the vault. Finder's list and column views don't do this. PhotoVault can't prevent it; it depends only on how you browse.

### Reveal in Finder

To see a photo's file in Finder, right-click it in the grid and choose **Reveal in Finder (list view only)**. Finder shows the folder in whatever view it was last set to. So set the Photos folder and the folders in it to list view, or column view, before you use this. In Finder, choose View › as List (⌘2).

### What PhotoVault does for you

- There are no Share or Print commands, and Edit › Copy never copies pictures.
- Dragging photos from the grid to Finder or another app copies nothing. Drags only work inside PhotoVault, onto folders and albums in the sidebar.
- PhotoVault keeps its settings in the vault's catalog and writes nothing to your Mac's preferences.
- JoyTag tags photos on your Mac without the internet, and nothing is written into your photos.
- A photo's location is shown as text only. No map is loaded.
- Spotlight is asked to stay out of the vault.
- When you switch to another app, PhotoVault releases the full-size pictures it was holding in memory.

## Using PhotoVault in a plain folder

PhotoVault is made to live in a disk image, but it also works in an ordinary folder, on your Mac's own disk or on an external drive. **It works, but it is mostly untested when used this way.** It has been tried far less than a disk image, so keep a separate backup of your photos and go carefully.

### Setting it up

1. Make a folder for the vault. Inside it, make a folder named exactly **Photos**, and put your photos and videos in it.
2. Open PhotoVault Installer, choose **Install on an Existing Vault** and click **Choose…**. Choose the folder you made, the one that holds Photos. The installer may list it under the name of the drive it's on, with the folder's location underneath. That's expected.
3. Click **Install**. PhotoVault.app, README.txt and .Tag Groups.txt go beside Photos. JoyTag goes into .catalog if photo tagging is ticked.
4. Click **Open PhotoVault**, or open PhotoVault.app from that folder.

You can also just copy PhotoVault.app into the folder beside Photos. Photo tagging then isn't available, and Image › Classifier says "Photo tagging isn't installed on this vault." There's no .Tag Groups.txt to edit either, so PhotoVault uses its built-in tag groups, and no README.txt. To add it, install on the folder as described above.

When PhotoVault opens, it looks for a .catalog folder in its own folder and in the folders above it. If it finds none, it looks the same way for a Photos folder. The first one it finds becomes the vault. If that's a Photos folder, PhotoVault starts a new catalog beside it. **Always keep PhotoVault.app right beside Photos.** Otherwise it may take a Photos folder further up as its vault.

To update PhotoVault in a plain folder later, follow Updating PhotoVault above. Use **Choose…** to pick the folder, because the installer only lists disk images by itself.

### How it differs from a disk image

- **No password.** The installer's password only protects disk images. A folder is only as private as the drive it's on.
- **Eject.** Vault › Eject Volume (⌘E) quits PhotoVault, then tries to eject the drive the folder is on. On an external drive, that ejects the whole drive, with everything else on it. On your Mac's own disk nothing is ejected and PhotoVault just quits.
- **Space.** There's no disk image to compact. Vault › Empty Trash… frees the space on the drive straight away.
- **Copying.** Quit PhotoVault (⌘Q), then copy the whole folder. Finder copies the hidden .catalog with it.
- **Spotlight.** PhotoVault still leaves its file asking Spotlight to stay out. That file is meant for a whole disk, so Spotlight may still index photos in a plain folder.
- **iCloud.** Don't put the folder in iCloud Drive, or in a Desktop or Documents folder that iCloud keeps in sync. Every photo would be uploaded to iCloud.
- **Finder.** The advice about icon and gallery views applies just the same.
"""#),
        Chapter(id: "help", title: "Troubleshooting", symbol: "questionmark.circle", markdown: #"""
## Opening PhotoVault

### macOS won't open PhotoVault Installer or PhotoVault

PhotoVault isn't notarized by Apple. The first time you open PhotoVault Installer, macOS says it can't check the app and won't open it. To open it anyway:

1. Try to open the app once. When macOS shows its message, close the message. Don't move the app to the Trash.
2. Open **System Settings › Privacy & Security** and scroll down to the Security section.
3. Click **Open Anyway**, then confirm that you want to open it.

macOS remembers your choice for that copy of the app, so you only do this once.

The PhotoVault that the installer puts on a vault opens without these steps. If a vault came from another Mac or from a download and macOS blocks PhotoVault, follow the same steps for PhotoVault.app. If PhotoVault then says "No .catalog folder found alongside the app", see the next question.

### PhotoVault says "No .catalog folder found alongside the app"

The full message is "No .catalog folder found alongside the app. Move PhotoVault.app to the top level of the vault." It appears in an alert titled "PhotoVault", and the status line at the top of the window reads "Not ready".

PhotoVault only works from inside its vault. It looks in the folder it is in, and in the folders above that one, for the vault's .catalog folder. If it finds a Photos folder instead, it starts a new catalog beside it. The message means it found neither. Usually PhotoVault was opened somewhere else, such as a copy in your Applications folder. Quit it, then open the PhotoVault.app at the top level of the vault, next to the Photos folder. Every vault has its own PhotoVault, so you never need to copy the app anywhere else.

### PhotoVault says it's running from a temporary copy

The message is "macOS is running this app from a temporary copy, so it can't find the vault. Quit, run `xattr -dr com.apple.quarantine` on the app, and reopen it." macOS is running PhotoVault from a hidden temporary copy, away from your photos. This happens when a vault came from another Mac or from a download. macOS marks PhotoVault as downloaded, and the temporary copy can't find the vault. To clear the mark:

1. Quit PhotoVault (⌘Q).
2. Open Terminal. It is in the Utilities folder inside Applications.
3. Type `xattr -dr com.apple.quarantine` followed by a space. Drag PhotoVault.app from the vault into the Terminal window to fill in its location, then press Return.
4. Open PhotoVault from the vault again.

Another way to fix it: open PhotoVault Installer, choose **Install on an Existing Vault** and install on this vault again. The copy it puts there opens normally, and the vault's photos, albums and tags stay as they are.

While the status line reads "Not ready", **Vault › Eject Volume** does nothing. Quit PhotoVault with ⌘Q instead, then eject the disk in Finder.

## Photos and videos

### Where are my videos?

Look at the **All**, **Photos** and **Videos** switch at the top left of the window, above the grid. Each view, such as All Media, a folder or an album, has its own setting and remembers it. A folder or album left on Photos still hides its videos when you come back to it. Click **All** or **Videos**, or choose **View › Show All** (⌘1) or **View › Show Only Videos** (⌘3). These work in the library. If a photo is open, press Esc to go back to the library first.

PhotoVault shows videos whose names end in .mov, .mp4, .m4v, .avi, .mkv, .webm, .mpg, .mpeg or .3gp, as long as they are inside the Photos folder. It doesn't show other kinds of video file.

### I added photos, but they don't appear

PhotoVault only shows what is inside the vault's Photos folder, including all the folders within it. It looks for changes every time it opens. If you added photos while it was open, choose **Vault › Rescan Changed Folders** (⌥⌘R).

You may have edited a photo in another app and it still looks the same in PhotoVault. If so, choose **Vault › Full Rescan** (⌥⇧⌘R). It checks every file, not just the folders that changed.

PhotoVault finds photos whose names end in .jpg, .jpeg, .png, .heic, .heif, .gif, .tif, .tiff, .bmp or .webp, and the videos listed above. It skips files and folders whose names start with a full stop.

### A video shows a question mark

A question mark in place of the play symbol means the player built into macOS, which PhotoVault uses, can't open this video. Some kinds of video, such as MKV, VP9 and older AVI files, play in other apps but not in that player. Its thumbnail is a grey square with a warning sign, because PhotoVault couldn't take a picture from it either. If you open the video, PhotoVault shows "No playable video track". The Properties panel (**Image › Show Properties**, ⌘I) says "This file can't be played."

The file itself is untouched. To watch it in PhotoVault, convert it to MP4 with a video app and put the converted copy in the Photos folder.

### A photo can't be rotated

PhotoVault only rotates JPEG photos, whose names end in .jpg or .jpeg. It changes only the note in the file that says which way up the picture goes. It never saves the picture again. That is why **Image › Rotate Left** (⌘L), **Image › Rotate Right** (⌘R) and the rotate buttons in the viewer are greyed out for:

- videos
- other kinds of photo, such as HEIC, PNG and TIFF
- photos in the Trash

If you select a mix of file types, only the JPEGs turn.

When a JPEG won't turn, an alert titled "PhotoVault" names the file and gives the reason. "the file is read-only." means the file is locked or can't be changed. **Vault › Fix Permissions…** fixes a locked or read-only file. If the whole vault is read-only, eject it and open it again with write access. Any other reason means PhotoVault couldn't change the file safely, so it left the file exactly as it was.

Rotating has no Undo. To put a photo back the way it was, rotate it the other way.

### I moved photos in Finder. Will they show twice, or lose their albums?

No. PhotoVault looks for changes when it opens, or when you choose **Vault › Rescan Changed Folders** (⌥⌘R). It then recognizes each moved or renamed photo by its contents and keeps its favorite, albums and tags. The same goes for folders you renamed or moved. Until then, it shows the photos in their old place.

This works as long as the photos stay inside the Photos folder. If you move a photo out of the Photos folder, or delete it, it disappears from PhotoVault. If you later put the same file back in the Photos folder, it comes back with its favorite, albums and tags.

If a photo appears twice, there are two files, because it was copied rather than moved. PhotoVault shows each copy.

**Image › Move to Folder** moves photos straight away, with no rescan needed.

### I put a photo back from the Trash, but it isn't in its albums

Moving a photo to the Trash takes it out of every album. Putting it back, by right-clicking it in the Trash and choosing **Put Back Photo**, doesn't add it to them again. If the photo was a favorite, it still is. Add it to its albums again.

To take a photo out of just one album, open that album, right-click the photo and choose **Remove Photo from This Album**.

## Moving and deleting

### A file can't be deleted or moved

This usually means macOS refused, not PhotoVault. Before **Vault › Empty Trash…** deletes anything, its question says how many files can't be deleted as things are, and why.

If Empty Trash or a move leaves some files behind, PhotoVault opens a window with a title such as "2 items couldn't be deleted" or "1 item couldn't be moved". It sorts the files by reason, such as "Locked" or "In a folder you can't change", explains each reason, and offers these buttons:

- **Unlock and Delete** or **Unlock and Move** turns off Locked on files that belong to you, the same as unticking Locked in Finder's Get Info. Then it tries again.
- **Delete with Administrator Password…** or **Move with Administrator Password…** handles files that belong to another user, files in a folder you can't change, and files macOS refused for another reason. macOS asks for the password in its own window. PhotoVault never sees it.
- **Show in Finder** shows the files so you can change them there. Then click **Try Again**.
- **Keep in Trash** or **Leave Them** closes the window and leaves the files as they are.

If the reason is "The vault is read-only", nothing on the vault can be changed. Eject the vault and open it again with write access.

To fix these problems before they happen, choose **Vault › Fix Permissions…**. It checks everything in the Photos folder and tells you what it found. If you click **Fix**, it changes only their permissions, never the photos. Files restored from a Time Machine backup often need this. If some files belong to another user, it then offers **Use Administrator Password…**. macOS asks for the password in its own window.

**Image › Move to Folder** is greyed out when nothing is selected, in the Trash, and while PhotoVault is busy scanning, tagging or moving photos. While it is busy, dropping photos on a folder does nothing too. Wait for it to finish, or click **Stop** in the status line at the top of the window. You can also choose **Vault › Stop Scan**, **Stop Tagging** or **Stop Moving** (⌘.).

## Tags

### Tagging isn't available

Open **Image › Classifier**. If tagging can't run, a greyed-out line at the bottom of that menu says why:

- "JoyTag needs macOS 15 or later." Tagging needs macOS 15 or later. Everything else in PhotoVault works on macOS 14.
- "Photo tagging isn't installed on this vault…" means **Include photo tagging (JoyTag)** was unticked when the vault was made or last updated. To add tagging, open PhotoVault Installer and choose **Install on an Existing Vault**. Pick this vault, tick **Include photo tagging (JoyTag)**, and click **Update** or **Reinstall**. Tagging takes about 370 MB on the vault. The vault's photos, albums and tags stay as they are.
- Any other line says that JoyTag's files on this vault are missing or can't be used, for example "JoyTag's model is missing from this vault." Install on the vault again the same way, with the box ticked.

**Tag Untagged Photos**, **Re-classify Selection With › JoyTag** and the right-click **Re-tag with JoyTag** are also greyed out while PhotoVault is scanning, moving or tagging photos.

After a scan, PhotoVault tags new photos by itself. If more than 100 need tagging, it asks first, with a question such as "Tag 2,500 photos with JoyTag?". If you click **Not Now**, it won't ask again until the next time it opens. To start sooner, choose **Image › Classifier › Tag Untagged Photos**.

### Some tags are missing, such as R18 tags

The vault's .Tag Groups.txt file has a group called R18, for nude and explicit content and graphic gore. Tags in that group are hidden unless **Image › Classifier › Show R18 Tags** is ticked. It starts unticked, unless a smart album already uses R18 tags. While they are hidden, they don't appear in the Properties panel or in a smart album's filter panel, including its search. Nothing tells you that some are hidden. Tick **Show R18 Tags** to see them. The vault remembers your choice.

Only the tags are hidden, never the photos. A smart album that uses R18 tags still finds its photos.

There are other reasons a tag might be missing from the filter panel:

- You hid it with right-click › **Hide Tag**. With the search box empty, click the "Show 1 hidden tag" link (the number may be higher) to see your hidden tags. To bring a tag back, right-click it and choose **Show Tag**.
- It is on fewer than 3 photos. Tick **Show rare tags (on fewer than 3 photos)**, or search for the tag.
- An open group shows its 12 most used tags first. Click the "Show all" link under the group to see the rest.

## The installer

### The installer says something went wrong

When the installer can't finish, it shows a title such as "The vault couldn't be created" or "PhotoVault couldn't be installed", with the reason under it. Click **Back** (↩) to return to the form, put the problem right, and try again.

- "There's already a vault called … there. Choose another name, or install on it instead." A disk image with that name is already in the folder you chose. Type another name, or choose **Install on an Existing Vault**.
- "The installer can't save in …. Choose another folder." Your account can't add files to that folder. Click **Choose…** beside **Save in:** and pick another, such as your home folder.
- "PhotoVault is still open from this vault. Quit it, then try again." PhotoVault didn't quit within about 15 seconds. Quit it with ⌘Q, then click the button at the bottom again.
- "JoyTag didn't copy completely. Is the vault full?" There wasn't room for photo tagging. Make room on the drive the disk image is saved on and install again, or install with **Include photo tagging (JoyTag)** unticked.
- "PhotoVault was copied, but its signature doesn't check out, so macOS may refuse to open it." Download PhotoVault Installer again, then install again.
- "Something in the vault's catalog changed while installing, and nothing should have. Check the vault before using it." Open PhotoVault from the vault and check that your albums, favorites and tags are as you left them.

If the installer says "This installer can't be used", part of it is missing and the only button is **Quit**. Download it again.

If you click **Open PhotoVault** and it doesn't open, the installer says "PhotoVault didn't open". Open PhotoVault.app from the vault's disk in Finder instead.

## Quitting, ejecting and the vault

### PhotoVault asks before quitting

PhotoVault only asks while it is busy scanning, tagging, re-tagging or moving photos. The question has a title such as "PhotoVault is still scanning" or "PhotoVault is still moving photos", and says how far it has got.

- **Stop and Quit** stops safely. A scan or tagging run picks up where it left off the next time PhotoVault opens. Photos that were already re-tagged keep their new tags, and the rest keep their old ones. Photos that were already moved stay in their new folder, and the rest stay where they were.
- **Keep Scanning**, **Keep Tagging** or **Keep Moving** lets the work carry on.

Closing PhotoVault's last window also quits it, so you get the same question. The manual opens in a window of its own. Closing the library window closes the manual too, and quits PhotoVault. **Vault › Eject Volume** (⌘E) asks too, with a **Stop and Eject** button. When the Mac logs out, restarts or shuts down, PhotoVault doesn't ask. It stops in the same safe way.

### PhotoVault shows "Catalog error" or "Thumbnail store error"

These alerts, titled "PhotoVault", mean PhotoVault couldn't read or write its own files in the vault's hidden .catalog folder. The words after the colon are the reason. "A thumbnail read came up short. The volume may have been ejected." means the vault's disk went away while PhotoVault was reading it. Quit PhotoVault and check that the vault's disk is there, has free space and can be written to. Then open PhotoVault again.

### The vault won't eject

While PhotoVault is open, Finder can't eject the vault. PhotoVault runs from the vault, so the vault is always in use. Choose **Vault › Eject Volume** (⌘E) instead. It quits PhotoVault first, then ejects the vault.

If you tried Finder's eject first, PhotoVault lets go of the vault and can't do anything more until you open it again. Choose **Vault › Eject Volume** (⌘E), or quit PhotoVault and then eject the vault.

If the vault is still there after PhotoVault has quit, something else is using it. Often macOS is still finishing with a video, which takes a moment. Wait a few seconds, then eject the vault in Finder. Also quit any other app that has a file from the vault open.

If your vault is an ordinary folder rather than a disk image, **Eject Volume** ejects the whole drive the folder is on. If the folder is on your Mac's own disk, it just quits PhotoVault. Using PhotoVault in an ordinary folder is mostly untested.

### The vault keeps getting bigger

A vault's disk image grows as you add photos, but it doesn't shrink by itself when photos are deleted.

- **Move to Trash** frees no space. The file stays in its folder until you choose **Vault › Empty Trash…**.
- **Empty Trash** deletes the files for good. Their space is then free inside the vault for new photos, but the disk image stays the same size on your Mac.
- PhotoVault keeps a small thumbnail of every photo and video in the vault's .catalog folder. The thumbnails only ever add up. When you delete, rotate or change a photo, its old thumbnail stays.
- Photo tagging takes about 370 MB. To free that room inside the vault, install PhotoVault on the vault again with **Include photo tagging (JoyTag)** unticked. Tags already made are kept.

To give the space back to your Mac:

1. Eject the vault with **Vault › Eject Volume** (⌘E).
2. Open Terminal. It is in the Utilities folder inside Applications.
3. Type `hdiutil compact` followed by a space. Drag the vault's disk image (the file whose name ends in .sparsebundle) into the Terminal window, then press Return.

Moving photos between folders, with PhotoVault or with Finder, doesn't make the vault bigger. If your vault is an ordinary folder, the space comes back as soon as you empty PhotoVault's Trash.

### The installer says the vault has a newer PhotoVault

When you choose **Install on an Existing Vault** and pick a vault, the installer compares versions. If the vault already has a newer PhotoVault than the installer carries, the installer shows a line with an orange warning sign. The line begins "It has a newer PhotoVault" and says that installing puts the older version in its place. The button then reads **Install Older Version**.

Usually this means your installer is out of date. Download the newest PhotoVault Installer, or keep using the PhotoVault that is already on the vault. If you click **Install Older Version**, the installer puts the older version in place without asking again.

### I forgot the vault's password

There is no way to recover it. macOS encrypts a password-protected vault. PhotoVault Installer hands the password straight to macOS and keeps no copy, and PhotoVault itself never sees it. Without the password, nobody can open the vault, on this Mac or any other, and its photos are lost. The installer warns about this when you make the vault.

If you let macOS remember the password in your keychain, this Mac may still open the vault without asking. If it does, copy your photos out of the vault while you still can, for example into a new vault. The new vault starts without the old one's albums, favorites and tags. Keep the new password somewhere safe, such as a password manager.
"""#),
    ]
}
