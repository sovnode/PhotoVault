PhotoVault
==========

Everything this app needs lives on this volume. Copy the sparse bundle
anywhere and it works: the catalog stores paths relative to the volume root
and never records a volume name, UUID, hostname or username.

The full user manual is inside PhotoVault: Help > PhotoVault User Manual
(Cmd-?).


Opening it on another Mac
-------------------------

A copied .app arrives quarantined, and macOS will either refuse to open it or
run it from a temporary read-only copy — in which case the app can't find the
vault it is sitting in and says so. Run these once, on the destination machine:

    xattr -dr com.apple.quarantine "/Volumes/PhotoVault/PhotoVault.app"
    codesign -s - -f --deep "/Volumes/PhotoVault/PhotoVault.app"

The second line is only needed if the app is unsigned or its signature broke
in transit.


Updating PhotoVault
-------------------

Open a newer PhotoVault Installer and choose Install on an Existing Vault.
It quits PhotoVault if it's open, replaces the app, and leaves your photos,
albums and tags as they are.


Copying the vault
-----------------

Eject the vault from PhotoVault (Cmd-E) first. A clean quit saves the
catalog as one self-consistent file; a copy made while PhotoVault is open can
catch it part-way through saving.

Then copy the .sparsebundle in Finder, as you would any file. That's always
fine. For a tidier copy, without the space left over from deleted photos,
hdiutil can make one instead:

    hdiutil convert -format UDSB -imagekey sparse-band-size=65536 \
        -o Copy.sparsebundle PhotoVault.sparsebundle

But a copy made that way has no password: copy a password-protected vault in
Finder.


Ejecting
--------

Use PhotoVault's own Eject Volume command (Cmd-E).

Finder's eject will fail with "volume in use" for as long as the app is open,
and this cannot be fixed from inside the app: the running binary is itself
mapped from this volume, so the volume is busy no matter what files the app
closes. Cmd-E quits first and then ejects, which is the only order that works.

If an eject still fails after quitting, something else is holding the volume:

    lsof +D /Volumes/PhotoVault

Usually that's mediaplaybackd or VTDecoderXPCService finishing with a video.
They need a moment; try again.


Deleting photos
---------------

Move to Trash only hides a photo and takes it out of its albums; Put Back
undoes that. Empty Trash (right-click Trash in the sidebar) permanently
deletes the original files from this volume, after asking.

A sparse bundle doesn't shrink when files are deleted. To reclaim the space,
eject the vault and run:

    hdiutil compact PhotoVault.sparsebundle


Keeping the photos on this volume
---------------------------------

The app never copies decoded images off the volume. One habit can, though:

    Do not browse the Photos folder in Finder's icon or gallery view.

Those views ask Quick Look for thumbnails, and Quick Look writes them into a
shared cache in your home folder. Finder's list and column views don't. No
code in the app can prevent this — it is entirely a matter of how you browse.


JoyTag
------

PhotoVault's automatic tags come from JoyTag (github.com/fpgaminer/joytag),
which lives in this vault's hidden .catalog/models/JoyTag folder with its
licence, the Apache License 2.0. It tags photos on this Mac, without the
internet, and its tags are kept in PhotoVault's catalog: nothing is written
into your photos. It needs macOS 15 or later.
