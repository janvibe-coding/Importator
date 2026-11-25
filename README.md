# Importator

Copies photos and videos from a card or folder into your library folder, leaves out the ones that are already there, and fills in a missing capture time on the copies. Made to sit next to [Photomator](https://www.pixelmator.com/photomator/)'s Files browser, but it works with any folder-based library.

- **Duplicates are found by what's in the files**, not by name: capture time, camera, file type and pixel size (creation time, duration and device for videos). Renamed copies and wrapped camera counters don't fool it. Set to **By content**, every match is also confirmed on the image data, so a JPG whose rating was changed still counts as the same photo.
- **Missing capture times are filled in on the copy.** Some phones (the Xiaomi 17 Ultra, for one) write the capture time of their DNGs where most apps don't look, so those photos show up without a date. Importator writes it into the standard place. Photos with no date at all get one from their file name or file date, marked as a guess.
- **Copies can be verified.** With **Verify copies** on, every copy is read back from the disk and compared with its original; a copy that differs is made again straight away.
- **The photo comes first.** Dates are written only after everything is copied (and verified). If a date can't be written, the file is still copied, unchanged, and the report says so.
- **Fix Missing Dates** (File menu) writes dates into folders you imported earlier.

Three panels, like Lightroom's import: the source (drives and folders; a card opens with its DCIM folder ticked, and has an eject button), the photos grouped by day, and the destination (Photomator's sidebar folders and your own). Duplicates show dimmed and unticked; hover to see where the existing copy is. Space opens a large preview.

## Install

1. Download the `.dmg` from [Releases](../../releases) and drag Importator into Applications.
2. Open it. The app isn't notarized, so macOS blocks it the first time. Go to System Settings → Privacy & Security and click **Open Anyway**.
3. macOS asks for access to removable volumes when you open a card, and may ask for access to other apps' data to show Photomator's sidebar folders. Allow both. If Photomator's folders don't show, turn Importator on under System Settings → Privacy & Security → **Full Disk Access**.

macOS 13 Ventura is the minimum, though it has only been tested on newer versions.

## What it reads and writes

Reads:

- The photos and videos in the folders you tick, and in the folder the duplicate check looks in (above the grid; by default the Photomator library that holds the destination, else the Pictures folder or the destination's parent).
- Photomator's sidebar folders from its list, `~/Library/Group Containers/4R6749AYRE.com.pixelmator/Library/Files Library/FilesLibrary.plist`. Read only.

Writes, only when you press **Import**:

- Copies of the ticked files into the destination folder. Each copy is written under a temporary name and renamed when complete; an existing file is never replaced (a copy whose name is taken gets `-2`). Copies keep the original's file dates. Nothing on the source is changed.
- With **Fix missing date** on, after all files are copied: `DateTimeOriginal` and `CreateDate` in the Exif data of the copy. Each date goes into a temporary copy first; the date must read back and a JPG's or DNG's image data must be unchanged before it replaces the copy.

**Fix Missing Dates** writes the same two fields into files in the folder you choose, after you press **Fix**. Each file is copied beside itself, fixed and checked there, and then replaces the original. Keep your own backup of your photos.

It never writes anything of Photomator's, keeps no import history, and makes no network connections.

## Build it yourself

Everything is here, so you don't have to trust a downloaded app. You need Xcode.

1. Open `Importator.xcodeproj`.
2. Choose Product → Scheme → Edit Scheme, set Run to **Release**, and run it.

The engine is a Swift package in `Engine/`, with a command-line tool (`swift run importator`) and tests (`swift test`). `SPEC.md` holds the design.

## Licence

MIT, see `LICENSE`. Includes [ExifTool](https://exiftool.org) by Phil Harvey, under its own licence.

Not affiliated with Photomator or Pixelmator.
