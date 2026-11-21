# Importator: specification

Version 1.0. Describes what the app does and why it does it that way.

Importator is a native Mac app that copies photos and videos from a card or folder into a
library folder, leaves out files that are already there, and fills in a missing capture time
on the copies. It can also fill in missing capture times in folders already imported.

## Why it exists

1. Photos get imported twice, and a folder-based library has no import history to stop it.
   Renamed copies and camera counters that wrap at 9999 make file names useless for this.
2. Capture times some apps can't see. The Xiaomi 17 Ultra writes `DateTimeOriginal` (0x9003)
   into IFD0 of its DNGs, with no Exif sub-IFD and no time zone. Photomator ignores it: its
   sidecars and exports carry only the modification date, so those photos don't sort by date.
   The phone's JPGs are fine; they are HEIC inside, despite the `.jpg` extension.

## What it never does

- Change, move or delete anything on the source during an import.
- Overwrite a file at the destination. (Fix Missing Dates replaces a file with its own checked,
  date-fixed copy; see below.)
- Write anything to Photomator: not its list, its sidebar or ratings. Photomator picks up
  subfolders of a sidebar folder by itself.
- Keep an import log or an "imported before" state: a file is in the library or it isn't.
- Make network connections.

## Main window

Three panels and a bottom bar, like Lightroom's import. No explanatory text on screen.

### Source

- **Drives:** every mounted volume. A volume with a DCIM folder is a card: it opens with its
  DCIM folder ticked, at launch and when it's inserted.
- **Folders:** folders added with "Choose folder…", remembered.

Ticking a folder ticks all its subfolders; each subfolder can be unticked. Every photo and
video in the ticked folders is shown.

### Grid

The files grouped by capture day, each cell with a tick box. "Check all · Uncheck all" and a
zoom slider at the top.

- A RAW and its JPG (same base name, same folder) share one cell. They remain two separate
  files in every other respect.
- Format tag on each cell: `RAF+JPG`, `CR3+JPG`, `DNG+JPG`, `DNG`, `JPG`, `MOV`, and so on.
- "no date" tag on files without a capture time in the Exif IFD: red while Fix missing date is
  off; green when it's on and the date comes from the file itself; orange when it will be
  guessed.
- A cell whose files are all found is a duplicate: dimmed and unticked. Ticked, it shows at full
  strength and is imported again. Hovering shows the folder of the existing copy.
- A cell where only one file is found is shown normally and ticked; Import copies only the
  missing file.
- Thumbnails come from the JPEG embedded in each file; Space opens a large Quick Look preview.
  Click, Shift-click and Cmd-click select.

### Destination

- **Photomator:** its sidebar folders, read only from `FilesLibrary.plist`, in sidebar order.
- **Folders:** folders added with "Choose folder…", remembered. The Pictures folder at first
  start when there are no sidebar folders.
- Subfolder (tick box and name), Rename ("date + original name": `20261003-IMG_1234`), Copy
  (RAW+JPG / RAW / JPG for pairs), Fix missing date, Compare fingerprints (off at every launch).
- Check duplicates in: a folder, remembered per destination. Default: the destination's parent.

### Bottom bar

"N of M selected" and Import. Import copies straight away, with a progress bar, and lists any
file that failed. There is no review step.

## Duplicate check

The check reads the files that are actually in the check folder: when it changes, after every
import, and whenever the app becomes active. Metadata only by default:

| Kind  | Matched on |
| ----- | ---------- |
| Photo | Capture date and time (plus subseconds when present), camera make and model, file type (from the content), pixel size |
| Video | Creation date and time, duration (to the millisecond), device, pixel size |

- The capture time is the Exif date, else the IFD0 date, else XMP CreateDate, so an unfixed DNG
  on the card matches its fixed copy in the library.
- A photo with none of these is matched on the date it would get (name or file date).
- Each file is checked on its own. The ticked source folders are left out of the check.
- File names are never used. Paths are compared in Unicode NFC.

With Compare fingerprints on, every metadata match is confirmed on content. Only matches are
hashed:

| Type | Fingerprint | Why |
| ---- | ----------- | --- |
| Camera RAW, video | SHA-256 of the whole file | Nothing writes into them |
| JPG | SHA-256 from the first SOS marker to the end | Photo apps write ratings into JPGs; the image data stays the same |
| DNG | SHA-256 of the main image's strips or tiles | Importator writes a date into DNGs |
| HEIC | Whole file | Not tested otherwise |

Phones may write no subseconds, so two shots in the same second match on metadata alone.
Compare fingerprints settles it.

## Missing capture time

With Fix missing date on, `DateTimeOriginal` and `CreateDate` are written into the Exif IFD of
the copy, with the bundled ExifTool. The date comes from the first source that has one:

| Source of the date | Tag colour |
| ------------------ | ---------- |
| IFD0 `DateTimeOriginal` | Green |
| XMP `CreateDate` | Green |
| A date in the file name (`IMG_20261003_134702`, `PXL_…`, `20260621-…`) | Orange |
| The file's modification date | Orange |

On these DNGs ExifTool creates an Exif IFD and removes the misplaced IFD0 date; the image data
stays identical. After every write the date must read back and a JPG's or DNG's image data
must be unchanged, or the file fails. No time zones are written or changed.

Phones don't always name files in the time zone of their capture time: a file name can be
hours off after travelling. That's why guessed dates are off by default in Fix Missing Dates.

## Fix Missing Dates

File › Fix Missing Dates… opens its own window, apart from the import window, so a source is
never changed by accident. Choose a folder (subfolders included); the "no date" files are
listed with their date and colour. Green is on by default, orange off. Each file is copied
beside itself under a temporary name, fixed and checked there, given the original's file dates,
and then replaces the original in one step.

## Copying

- Copy, never move. Copies keep the source's creation and modification dates.
- Each file is written under a hidden temporary name and renamed when complete, with a rename
  that can't replace an existing file. Leftover temporary files are removed on the next import.
- A taken name gets `-2`, `-3`, …, the same for both files of a pair, so the pair stays a pair.
- Free space is checked before copying starts. Only photos and videos are copied.

## Code structure

- `Engine/`: a Swift package with the `ImportatorEngine` library, the `importator` command-line
  tool (`scan`, `import`, `info`, `sidebar`) and tests: source scanner, metadata reader (ImageIO,
  and ExifTool where ImageIO misses), duplicate finder, copier, date fixer, sidebar reader.
- `App/`: the SwiftUI window. It only calls the engine.

Minimum macOS 13. App Sandbox off. ExifTool is bundled and run with macOS's Perl.

## Left out on purpose

- A plan or review step before Import.
- Undo, an import log, an "imported before" state.
- Time zone fixes.
- Hashing unless Compare fingerprints is on.
- Writing anything to Photomator.
- Import presets, a second copy, ejecting the card.
