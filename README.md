<div align="center">

<img src="assets/icon.png" alt="Glance Icon" width="160" height="160" />

# 📸 Glance for macOS ⚡

### The ultra-fast, native macOS photo viewer & pro culling tool 🚀  
*Instant full-screen folder browsing, zero-latency keyboard navigation, and pro RAW culling.*

[![Release 🎉](https://img.shields.io/github/v/release/mortalezz/glance?color=00c7b7&style=flat-square&label=Release%20%F0%9F%8E%89)](https://github.com/mortalezz/glance/releases/latest)
[![macOS ](https://img.shields.io/badge/macOS-13.0%2B-000000?style=flat-square&logo=apple&logoColor=white&label=%EF%A3%BF%20macOS)](https://github.com/mortalezz/glance)
[![Swift 🧡](https://img.shields.io/badge/Swift-5.9%20%2F%206-FA7343?style=flat-square&logo=swift&logoColor=white&label=%F0%9F%A7%A1%20Swift)](https://github.com/mortalezz/glance)
[![Engine ⚡](https://img.shields.io/badge/Zero%20Electron-Pure%20Native-blueviolet?style=flat-square&label=%E2%9A%A1%20Engine)](https://github.com/mortalezz/glance)
[![Speed 🚀](https://img.shields.io/badge/Lookahead-Zero--Latency-brightgreen?style=flat-square&label=%F0%9F%9A%80%20Speed)](https://github.com/mortalezz/glance)
[![Metadata 🏷️](https://img.shields.io/badge/Adobe%20XMP-Lightroom%20%26%20C1-orange?style=flat-square&label=%F0%9F%8F%B7%EF%B8%8F%20XMP)](https://github.com/mortalezz/glance)
[![License 📄](https://img.shields.io/badge/License-MIT-blue?style=flat-square&label=%F0%9F%93%84%20License)](LICENSE)

</div>

---

> [!NOTE]
> ### 🕊️ The Premise of Glance: Passing the Torch from Phoenix Slides
>
> For years, one utility reigned supreme on the Mac for quick folder inspection: **Phoenix Slides**. It solved a deceptively simple problem better than anything else before or since:
>
> 🎯 **Open any picture from a folder straight into a full-screen view, and immediately fly through the entire directory with pure keyboard navigation.**
>
> While Phoenix Slides still receives occasional maintenance patches to stay alive on modern macOS, its legacy architecture and dated UI show their age on Apple Silicon—especially when confronted with modern high-resolution sensors and RAW workflows. Meanwhile, newer image viewers have drifted to the opposite extreme: bloated web-wrapped apps or heavy catalog managers that demand importing photos into proprietary databases before you can even look at them.
>
> **Glance** was born directly out of that gap—taking the instant, zero-friction philosophy of Phoenix Slides and rebuilding it from the ground up for modern macOS and pro photography workflows:
>
> 1. 🖼️ **Finder-Direct Full Screen:** Open any photo directly from Finder straight into an edge-to-edge viewport.
> 2. ⚡ **Zero-Latency Traversal:** Fly through the entire folder with arrow keys or `Space`—zero lag, zero spinners, zero waiting.
> 3. 🫧 **Native macOS Vibrancy:** Clean, distraction-free viewing with frosted-glass HUD overlays that vanish when you don't need them.
>
> From this foundation, Glance adds modern pro culling superpowers: **1:1 pixel peeping**, **2-up burst compare**, **Adobe XMP sidecar sync**, **hardware-accelerated histograms**, and **exposure blinkies**.

> [!TIP]
> 💡 **Community Testing & Feedback Welcome!**  
> Glance is open-source and actively evolving. Feedback, feature requests, and testing on real-world photo shoots from photographers and Mac enthusiasts are always warmly welcomed!

---

## ⚡ Proud Features

| Feature | Highlight |
| :--- | :--- |
| 🚀 **Zero-Latency Keyboard Navigation** | Speculative triple-buffering and asynchronous background lookahead decode make folder traversal instantaneous on 45MP+ RAW and high-resolution JPEG files. |
| 🔍 **100% 1:1 Pixel Peep (`Z` / Click)** | Instant zoom to actual device sensor pixels centered right under your mouse cursor, with silky-smooth trackpad and mouse panning. |
| 👥 **2-Up Burst Compare (`S` / `Tab`)** | Side-by-side split comparison to catch micro-blur, closed eyes, and critical focus differences between consecutive frames, complete with synchronous 1:1 panning. |
| 🏷️ **Adobe XMP Sidecar Synchronization** | Real-time, non-destructive rating (`★`), color tagging, and flag management fully compatible with **Adobe Lightroom Classic, Capture One, Darktable, and Photo Mechanic**. |
| 🗂️ **RAW + JPEG Sibling Stacking** | Automatically pairs camera RAWs (`.ARW`, `.CR2`, `.CR3`, `.NEF`, `.RAF`, `.DNG`, etc.) with companion JPEGs, browsing the fast preview and inspecting master RAW sensor data during zoom. |
| ⚡ **Sub-5ms Embedded RAW Decoding** | Standalone RAW files extract the camera’s high-resolution embedded preview during folder scrubbing (`kCGImageSourceCreateThumbnailFromImageIfAbsent: false`), deferring full 60MP sensor demosaicing until 1:1 zoom. |
| 🛡️ **Silent FSEvents Directory Sync** | Monitors folder for new photos with `kFSEventStreamCreateFlagIgnoreSelf` and path filters, completely ignoring Glance’s own XMP writes to eliminate cache thrashing. |
| 📊 **Hardware RGB & Luminance Histogram (`H`)** | 256-bin SIMD/vImage hardware-accelerated histogram rendered inside an Apple Vibrancy frosted-glass HUD with shadow and highlight clipping indicators. |
| 🚨 **Exposure Clipping Warnings / "Blinkies" (`O`)** | Animated pulsating zebra overlays for overexposed blown highlights (Red) and underexposed crushed shadows (Blue). |
| 📷 **Dedicated Frosted EXIF HUD (`I`)** | Displays lens model, camera body, shutter speed, aperture, ISO, focal length, and capture date in a clean glass overlay. |
| 🔄 **Lossless EXIF Rotation (`R` / `]` and `L` / `[` )** | Rotates JPEGs, HEICs, and RAW XMP sidecars in 90° increments without re-compressing pixels. |
| 📦 **One-Key Quick Export (`E`)** | Copies all flagged Picks (or current photo) and companion sidecars to `./Picks` with sound confirmation and Finder reveal. |
| 📽️ **Hands-Free Slideshow (`Return`)** | Full-screen automated slideshow with live `+` / `-` speed stepping (1s to 30s) and instant pause on any interaction. |
| 🪶 **Zero Bloat, Zero Electron** | Pure native Swift & AppKit, compiling down to a lightweight standalone binary without web runtimes. |

---

## ⌨️ Complete Keyboard Shortcuts Cheatsheet

Press **`?`** (`Shift + /`) at any time inside Glance to toggle the interactive frosted-glass shortcuts cheatsheet.

### 🏷️ Culling & Rating
| Key | Action | Description |
| :---: | :--- | :--- |
| **`P`** | **Pick / Flag 🟢** | Mark photo as a keeper with vibrant green badge |
| **`X`** | **Reject 🔴** | Mark photo as a reject for deletion |
| **`U`** | **Unflag ⚪** | Clear pick / reject status to neutral |
| **`1` – `5`** | **Star Rating ⭐** | Rates image `★` to `★★★★★` (vibrant gold) |
| **`0`** | **Clear Rating ✖️** | Clears star rating |
| **`6` – `9`** | **Color Labels 🎨** | `6`: Red 🟥 &nbsp; `7`: Yellow 🟨 &nbsp; `8`: Green 🟩 &nbsp; `9`: Blue 🟦 |
| **`C`** | **Auto-Advance ⚡** | **Speed Culling**: Any tag/rating automatically steps to the next photo |

### 🔍 Review, Focus & Comparison
| Key | Action | Description |
| :---: | :--- | :--- |
| **`Z`** / **Click** | **100% Pixel Peep 🔍** | Zoom to 1:1 sensor pixels at cursor; drag to pan |
| **`S`** / **`Tab`** | **2-Up Compare 👥** | Side-by-side comparison with synchronous 1:1 zoom & pan |
| **`\`** | **Cycle Filters 🔀** | Cycles: `All` ➔ `Hide Rejects` ➔ `Picks Only` ➔ `Rejects Only` ➔ `Unrated` ➔ `3+ Stars` ➔ `5 Stars` |

### 📊 Exposure & Information Overlays
| Key | Action | Description |
| :---: | :--- | :--- |
| **`H`** | **RGB Histogram 📊** | Live 256-bin RGB & Rec. 709 Luminance histogram HUD |
| **`O`** | **Exposure Clipping 🚨** | Pulsing highlight (Red) and shadow (Blue) "blinkies" |
| **`I`** | **EXIF Info HUD 📷** | Frosted-glass camera, lens, and exposure parameters overlay |
| **`?`** | **Cheatsheet 💡** | Toggle shortcuts cheatsheet |

### 🛠️ Workflow & Output
| Key | Action | Description |
| :---: | :--- | :--- |
| **`R`** or **`]`** | **Rotate CW ↷** | Lossless 90° clockwise rotation |
| **`L`** or **`[`** | **Rotate CCW ↶** | Lossless 90° counter-clockwise rotation |
| **`E`** | **Quick Export 📦** | Copies all Picks (or current photo) to `./Picks` folder |
| **`Return`** | **Slideshow 📽️** | Start/stop automated hands-free slideshow |
| **`+`** / **`-`** | **Slideshow Speed ⏱️** | Increase / decrease slideshow interval at set steps (1s – 30s) |
| **`Delete`** / **`Backspace`** | **Trash 🗑️** | Move active file (and its RAW / XMP pair) to macOS Trash |
| **`Shift + Delete`** | **Purge Rejects 💥** | Safely batch moves all rejected (`X`) images to macOS Trash |

### 🧭 Navigation
| Key | Action |
| :---: | :--- |
| **`→`**, **`Space`**, **`↓`**, **`N`** | Next image ⏩ |
| **`←`**, **`↑`**, **`Page Up`**, **`K`** | Previous image ⏪ |
| **`Home`** / **`End`** | First / Last image in folder 🏁 |
| **`F`** | Toggle Full Screen ⛶ |
| **`Esc`**, **`Q`** | Close / Exit ✕ |

---

## 🚀 Download & Installation

### Option 1: Install via Homebrew 🍺 (Recommended)
```bash
brew install --cask --no-quarantine mortalezz/tap/glance
```
> **Note:** Because Glance is distributed outside the Mac App Store and ad-hoc signed, passing `--no-quarantine` prevents macOS Gatekeeper from displaying the unverified developer warning. If poured without it, run `xattr -cr /Applications/Glance.app` once.

*Or tap the repository first:*
```bash
brew tap mortalezz/tap
brew install --cask glance
```

### Option 2: Direct Download 📦
Download the latest pre-compiled application bundle from the [**Releases Page**](https://github.com/mortalezz/glance/releases/latest):
1. Download **`Glance-v1.1.0-macOS.zip`**.
2. Unzip and drag `Glance.app` into your `/Applications` folder.
3. Right-click any image in Finder ➔ *Open With* ➔ *Glance* (or set Glance as your default image viewer for instant full-screen glory).

### Option 3: Build from Source 🛠️
```bash
# Clone the repository
git clone https://github.com/mortalezz/glance.git
cd glance

# Build and package the release application bundle
./scripts/build_app.sh

# Launch Glance with any folder or photo:
open Glance.app /path/to/folder
```

---

## 🧪 Engineering Test Suite 🔬

Glance comes with a comprehensive standalone verification test suite covering XMP parsing, RAW+JPEG stacking, histogram math, clipping algorithms, and lossless rotation:

```bash
swiftc -o /tmp/test_glance \
  Sources/Glance/Model/CullingMetadata.swift \
  Sources/Glance/Model/SlideItem.swift \
  Sources/Glance/Model/ExifMetadata.swift \
  Sources/Glance/Engine/SupportedFormats.swift \
  Sources/Glance/Engine/DirectoryScanner.swift \
  Sources/Glance/Engine/XmpSidecarManager.swift \
  Sources/Glance/Engine/HistogramEngine.swift \
  Sources/Glance/Engine/ClippingEngine.swift \
  Sources/Glance/Engine/ExportManager.swift \
  Sources/Glance/Engine/LosslessRotationEngine.swift \
  scripts/test_xmp.swift && /tmp/test_glance
```

---

## 🔮 Looking Ahead: v1.2.0 Roadmap

<details>
<summary><b>Click to expand planned features for Glance 1.2.0 (Theme: <i>Focus & Velocity</i>)</b></summary>

<br />

### 👁️ Focus & Sharpness Superpowers (Apple Neural Engine / Vision)
- **Auto Face & Eye Jump (`Z` Double-Tap / `Shift + Z`)**:
  - Leverages macOS’s built-in, offline `Vision.framework` on Apple Silicon.
  - Automatically detects subject faces and eyes in portrait/event shoots. Double-tapping `Z` centers 100% zoom directly on the primary subject’s eye without manual panning across 60MP sensors.
- **Focus Peaking Overlay (`Shift + F`)**:
  - Real-time neon edge-contrast highlighting overlay (similar to camera EVFs).
  - Instantly reveals whether critical pupil focus was nailed in under 100ms.

### 👥 High-Speed Burst Culling & Safety
- **4-Up Quad Compare (`Shift + S`)**:
  - 2×2 grid comparison for consecutive high-speed burst shots with synchronous 1:1 zoom and pan.
  - Number keys `1`–`4` instantly select the winning frame and mark the others for rejection.
- **Multi-Level Undo & Redo (`Cmd + Z` / `Cmd + Shift + Z`)**:
  - Dedicated in-memory undo buffer for culling tags, star ratings, color labels, and accidental file trashing.

### 🎨 Color Fidelity & Apple XDR Display Engine
- **Camera Film Simulation & Picture Profiles**:
  - Native rendering of embedded camera color styles (Fujifilm Film Simulations like Classic Chrome/Astia, Sony Creative Looks, and Nikon Picture Controls).
- **Liquid Retina XDR / EDR Highlights**:
  - Leverages 1,000–1,600 nit specular highlight headroom on MacBook Pro and Pro Display XDR screens via Apple’s Extended Dynamic Range pipeline.

### 🎛️ Tactile Polish & External Retouch Handoff
- **Force Touch Trackpad Haptics**:
  - Subtle mechanical click feedback via `NSHapticFeedbackManager` whenever a rating (`1`–`5`), pick (`P`), or reject (`X`) is toggled.
- **External App Quick Handoff (`Cmd + Enter`)**:
  - One-key handoff to immediately open the current master RAW or photo in Photoshop, Lightroom Classic, or Capture One for detailed retouching.

</details>

---

## 📄 License ⚖️

Glance is open-source software licensed under the [MIT License](LICENSE).
