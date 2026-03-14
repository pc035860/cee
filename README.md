# Cee

**[English](README.md)** | [繁體中文](README.zh-TW.md)

A lightweight macOS image viewer, designed as a replacement for XEE.

Open an image and Cee automatically scans the folder for all supported images, letting you browse them with keyboard or mouse.

**Requirements:** macOS 14.0 (Sonoma) or later, Apple Silicon (M1 or later)

**License:** [MIT License](LICENSE)

---

## Features

### Image Browsing
- Open images via Finder right-click "Open With", auto-loads all images in the same folder
- Choose to open images in the same window or a new window (Window menu > Reuse Window)
- Supported formats: JPEG, PNG, TIFF, HEIC/HEIF, GIF, WebP, BMP, PDF
- Keyboard shortcuts for navigation (Cmd+]/[ to switch images)
- Left/Right arrow keys pan zoomed images; at the edge, press 3 more times to turn the page (with coral gradient progress indicator)
- Up/Down arrow keys scroll vertically (no page turn by default; configurable in Navigation menu)
- PageUp/PageDown/Space for page-by-page scrolling, auto-turns at top/bottom
- Option+Arrow keys jump 10 images at once (single-page mode)
- Drag-and-drop images or folders to open (supports browse view, grid view, and empty state)
- Subfolder auto-discovery: dropping a folder with no top-level images automatically finds the first subfolder containing images (BFS, max depth 2)

### Zoom & Display
- Pinch-to-zoom, Cmd+Scroll wheel zoom
- Fit to screen / Actual pixels / Custom zoom
- Zoom status display: FIT (auto-fit), ACTUAL 100%, or MANUAL xx% with optional WINDOW AUTO suffix
- Fullscreen mode, always-on-top window
- Fill window height without entering fullscreen (⌥⌘F)
- GPU-accelerated rendering via CALayer
- Bottom status bar showing dimensions, index, and zoom level (Cmd+/ to toggle)
  - Adaptive display: full info in regular windows, percent-only in narrow windows, zoom hidden in minimal mode
- Auto-resize window on open (optional), re-applies fit during window resize
- Separate sensitivity settings for trackpad and mouse wheel

### Quick Grid
- Press **G** to toggle a thumbnail grid overlay of all images in the folder
- Click or press Enter to jump to an image; press G or Esc to dismiss
- Pinch, Cmd+Scroll, Cmd+=+- to resize grid cells; slider at the bottom for fine control
- Dynamic cell aspect ratio based on folder content
- Grid persists across folder changes and accepts drag-and-drop

### Continuous Scroll
- Webtoon-style vertical continuous scrolling mode (Navigation menu or right-click context menu to toggle)
- All images in the folder are laid out vertically, scroll through them seamlessly
- Configurable image gap (0 / 2 / 4 / 8 pt) in the Navigation menu
- Zoom support with fit-to-width baseline
- GPU-accelerated rendering with view recycling for smooth performance
- Memory-pressure-aware: automatically reduces buffer on low memory

### Dual Page View
- Side-by-side two-page display with height normalization
- RTL (right-to-left) reading direction support; separate RTL navigation toggle for dual-page and single-page modes (Navigation menu)
- Spread-aware navigation

### Fast Browse
- Optional low-res thumbnail preview while navigating (View menu: "Use Low-Res Preview While Browsing")
- Directional prefetch for smooth browsing
- Option+Scroll wheel for rapid image switching with position HUD overlay
- Navigation throttle (~20fps) with delayed full-res load

### PDF
- Per-page PDF browsing with remembered last-read page
- Cancelable prefetch for PDF pages

### Mouse & Gestures
- Mouse drag to pan (cursor changes to hand icon)
- Three-finger trackpad drag to pan
- Trackpad edge-start swipe for page turn
- Click to turn page: left-click turns to next image, Shift+click turns to previous (optional, enable in Navigation menu)
- Cmd+Scroll for zoom at viewport center

---

## Building from Source

Cee does not currently provide prebuilt releases. You need to build it yourself.

### 1. Install Prerequisites

Requires **Xcode 16 or later** (install from Mac App Store) and **xcodegen** (generates the Xcode project file):

```bash
brew install xcodegen
```

If you don't have Homebrew, see [brew.sh](https://brew.sh).

### 2. Clone the Repository

```bash
git clone <repo-url>
cd cee
```

### 3. Generate Xcode Project

The `.xcodeproj` is not checked into Git; generate it with xcodegen:

```bash
xcodegen generate
```

### 4. Open and Run in Xcode

```bash
open Cee.xcodeproj
```

Select the `Cee` scheme and `My Mac` as target, then press Cmd+R to run.

#### Or Build from Command Line

```bash
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

The built `.app` will be at:

```
build/Debug/Cee.app
```

Double-click to run, or drag it to `/Applications`.

---

## Usage

### Opening Images

- **From Finder:** Right-click an image > Open With > Cee
- **From the app:** Cmd+O to open the file picker
- **Drag and drop:** Drop image files or folders onto the window

Cee automatically scans the folder for all supported image formats.

### Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Next image | Cmd+] or Right arrow (at edge) |
| Previous image | Cmd+[ or Left arrow (at edge) |
| Jump 10 images forward | Option+Right arrow |
| Jump 10 images back | Option+Left arrow |
| First image | Home |
| Last image | End |
| Scroll down one page | Space or PageDown |
| Scroll up one page | PageUp |
| Fit to screen | Cmd+0 |
| Actual size | Cmd+1 |
| Zoom in | Cmd+= |
| Zoom out | Cmd+- |
| Fullscreen | Cmd+F |
| Fill window height | Option+Cmd+F |
| Exit fullscreen | Esc |
| Toggle status bar | Cmd+/ |
| Toggle Quick Grid | G |
| Open file | Cmd+O |
| Close window | Cmd+W |
| Quit | Cmd+Q |

> **Arrow key behavior:** Left/Right arrows pan the image when zoomed; at the edge, press 3 more times to turn the page (a coral gradient indicator shows progress). Up/Down arrows scroll only and do not trigger page turns by default (configurable in Navigation menu). When the image fits within the window, Left/Right arrows switch images directly.

> **PageDown / Space behavior:** Scrolls the image by one page; press once more at the bottom to go to the next image. Same for PageUp.

### Zoom

- **Pinch gesture**: Two-finger trackpad zoom
- **Cmd+Scroll**: Zoom in/out
- **Cmd+0**: Fit to screen
- **Cmd+1**: Actual pixel size

---

## Development

### Run E2E Tests

```bash
./scripts/test-e2e.sh
```

Automatically builds and runs all XCUITest smoke tests.

### After Modifying Project Structure

After adding/removing files or changing target settings, regenerate the Xcode project:

```bash
xcodegen generate
```

> `Cee.xcodeproj` is auto-generated — do not edit manually.
