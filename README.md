# Halation

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)

A fast, native macOS photo viewer and editor.

I switched from Windows to Mac and couldn't get used to how macOS handles
looking at photos: open an image and you're stuck with it, with no obvious
way to flick through the rest of the folder. Halation fixes that. Open one
photo and the arrow keys take you through everything else in the folder,
full screen if you want, with a proper edit mode for when a shot needs a
quick fix.

The name comes from film photography: halation is the soft glow that bleeds
around bright highlights.

It's pure Swift (SwiftUI + AppKit), no dependencies, and the whole app is a
single small binary. You don't even need Xcode to build it, just Apple's
Command Line Tools.

## Install

```bash
git clone https://github.com/Kit-314/Halation.git
cd Halation
./build.sh
```

That builds the app and installs it to `~/Applications/Halation.app`.
Requires macOS 14 or later and the Command Line Tools
(`xcode-select --install` if you don't have them).

To open photos with it: right-click an image in Finder and pick
Open With > Halation. If you want it as your default viewer, do Get Info on
an image, change "Open with" to Halation and hit Change All. You can also
drag a photo or a whole folder onto the window or the Dock icon.

## Keyboard

| Key | Action |
|---|---|
| ← → / ↑ ↓ / Space | Previous / next photo in folder |
| Home / End / PgUp / PgDn | First / last / prev / next |
| F | Full screen (Esc exits) |
| + / − / 0 / 1 / 2 / 3 | Zoom in / out / fit / 100% / 200% / 300% |
| R / ] / [ | Rotate (view only) |
| I | Info panel with EXIF |
| T | Thumbnail filmstrip |
| S | Slideshow |
| H | Hide the toolbar |
| ⌫ | Move photo to Trash |
| E | Edit mode |
| ? | Cheat sheet |

The mouse wheel zooms at the cursor. Trackpads pan with two fingers and
zoom with pinch (or option-scroll). Double-click toggles between fit and
100%.

All of these can be remapped in Settings (⌘,) under Shortcuts: click the +
next to an action and press whatever key you'd rather use. An action can
have several keys, and if you assign a key that's already taken it just
moves over.

## Editing

Press E. You get a live-preview panel with:

- presets (Punch, Soft, Warm, Cool, Mono, Fade)
- rotate / flip / straighten, and crop with aspect presets
- exposure, contrast, highlight recovery, shadows
- saturation, vibrance, warmth, tint
- sharpness and vignette

Nothing touches the file until you save. Save overwrites the original
(it asks first, and the write is atomic), Save As writes a new
JPEG/PNG/HEIC/TIFF next to it. EXIF metadata survives either way.

C compares against the unedited original. Double-click a slider label to
reset it. Esc backs out of the crop, then out of edit mode.

Editing runs on Core Image, so the preview is GPU-accelerated and works
from a downsampled copy; the full-resolution render only happens when you
save.

## Settings

Appearance (system/light/dark), photo transition style (the default
"Cinematic" is a subtle directional drift + fade; there's also plain Fade,
Slide, and None), sort order, slideshow speed, and the shortcut remapper.

Everything is remembered between launches, including the last folder you
had open.

## Code tour

The interesting bits:

- `ViewerModel.swift` is the hub: folder scanning, navigation, key
  dispatch, file ops, the edit-session lifecycle
- `ZoomableImageView.swift` wraps NSScrollView for the zoom/pan canvas
- `ImageLoader.swift` does async ImageIO decoding with caching and
  preloading. Navigation shows a fast screen-sized preview first, then
  silently swaps in the full-resolution decode, which is why arrow-keying
  through a folder of big HEICs feels instant
- `EditEngine.swift` is the Core Image pipeline and file export
- `Keymap.swift` handles the remappable shortcuts

`gen-icon.swift` regenerates the app icon if you fancy a different one.

## Maybe someday

- watch the folder for new/deleted files
- a contact-sheet grid view
- histogram and curves
- star/color-tag culling that writes Finder tags

Issues and PRs welcome.

## License

[MIT](LICENSE)
