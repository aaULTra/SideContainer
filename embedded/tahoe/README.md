# Tahoe desktop integration — first milestone

Native iPad desktop shell built as an opt-in presentation for the existing
LiveContainer + SideInstaller flavour. `feature/livecontainer-sideinstaller`
and the original build workflow remain the fallback. Host identity, groups,
extensions, signing and guest data paths are unchanged.

## Implemented

- One state model for browser, Finder, settings, application catalogue and
  guest windows: drag, eight resize edges/corners, focus, minimise/restore,
  maximise/restore, left/right snapping and fullscreen.
- Dock with pointer-distance magnification and window restore buttons; menu
  commands, searchable app catalogue and a window overview.
- Stable native WKWebView sessions with tabs, address/search, desktop content
  requests, navigation controls, popup tabs and visible page-process errors.
  Layout updates do not reload pages. Tabs share WebKit's normal persistent
  website data store. A close explicitly releases that window's pages.
- Finder for files in `Documents/TahoeDesktop/Files`: folder creation,
  importing copies through the system picker, directory navigation and Quick Look.
  No unrestricted access to the iPad filesystem is claimed.
- Opt-in guest presentation after LCAppModel's existing preparation. Per-guest
  PID/error callbacks, bounded PID wait, explicit termination and handling a
  close that races extension startup. No second LC-managed window is created.
- Fullscreen preserves the window tree and hides wallpaper/Dock/menu rendering.
  Performance fullscreen asks before releasing other browser pages; resume
  reloads their saved addresses and loses unsaved page state/back history.
  Hiding a window does not claim to suspend its JavaScript or guest process.
- Native glass on iPadOS 26+ and materials on older supported releases;
  Reduce Transparency and Reduce Motion support.

Desktop catalogue launch intentionally starts with non-JIT, non-classic,
non-32-bit apps. Other guests remain available through the original management
UI, whose existing JIT flow is retained. The shared presentation hook receives
its callbacks too, but JIT guests in desktop windows are not device-validated.
Original LiveContainer startup checks and URL handlers stay mounted. Management
has a Return to Desktop control; switching interfaces does not remove guest views.

## Build

Run **Build Tahoe Desktop + LiveContainer** on the isolated branch. It uses the
same pinned runtime and packaging checks as the combined build, adding:

```sh
python3 embedded/prepare_livecontainer.py vendor-livecontainer --tahoe
swiftc embedded/tahoe/WindowState.swift embedded/tahoe/Address.swift \
  embedded/tahoe/WindowStateTests.swift -o /tmp/tahoe-tests
/tmp/tahoe-tests
```

`prepare_livecontainer.py` must receive a fresh checkout at
`4dbe0f9a626de801184a42c0be8d2cb105058e3d`. Without `--tahoe` it retains the
existing presentation. The desktop files are copied into the pinned project's
synchronised SwiftUI source group; no runtime dependency on React/Vue/Flutter
is introduced. Use Xcode 26 or newer for the availability-guarded glass APIs.

Download the `Tahoe-Desktop-LiveContainer-experimental` artifact. Its IPA retains
the existing packaging filename `LiveContainer-SideInstaller-unsigned.ipa`.
Use the existing team's application identity and retain every extension when
signing. A successful CI build does not establish guest compatibility.

## Source references and actual reuse

| Source | Inspected revision | Contribution / licence |
| --- | --- | --- |
| [sylonik/macos-ui](https://github.com/sylonik/macos-ui) | `bcdea1df8c52b97cfa3f0b9620e4953dc7a6633d` | Window state transitions and Dock distance falloff adapted natively; MIT notice included. Bounds, opposite-edge resizing and restore semantics extended. |
| [antonreshetov/macvue](https://github.com/antonreshetov/macvue) | `7a9cc21515e3522e63d91d70690a94eecec50564` | Regular button height/radius token family used for native controls; MIT notice included. Chromium SVG glass is not embedded. |
| [macosui/macos_ui](https://github.com/macosui/macos_ui) | `dec19cf6960721f80165ead6c9c19594030b292f` | Bounded sidebar and narrow-window collapse pattern adapted; MIT notice included. No macOS window utility calls are used. |
| [tamnguyenvan/macos-components](https://github.com/tamnguyenvan/macos-components) | `e82dbfa3702a156e4b9947337dea3d496a162905` | Inspected Tahoe control/window/sidebar specifications to assess design consistency. No reuse licence found; implementation and assets are not copied. Direct port deferred until permission/licence is available. |
| [aaULTra/MacOS-Clone-SwiftUI](https://github.com/aaULTra/MacOS-Clone-SwiftUI) | `e16bdbd257a15f48bba681759c5c4a6b73ce988b` | Existing desktop hierarchy, Dock and menu-bar interaction baseline inspected. Repository and working IPA untouched; no clone source or artwork copied because its reuse licence is not established. |

The visual assets in this milestone use system symbols and an original gradient.
Matching the tested clone's exact artwork and further Tahoe styling remains work.

## Device acceptance sequence

1. Launch the desktop and open management. Check existing installed guests,
   certificate settings and embedded SideInstaller. Return to desktop.
2. Open two browser windows. Navigate, enter text, switch tabs, drag, resize from
   every edge, minimise via yellow, restore via Dock and tile left/right.
3. Open a simple non-JIT guest from Applications. Check touch, keyboard focus,
   resizing, minimising/restoring, management switching and explicit close.
4. Close a guest immediately after launch. Confirm no orphan guest remains.
   Also test invalid signing, missing LiveProcess, startup error and guest crash.
5. Fullscreen a browser and a guest separately. Exit with the visible control.
   Confirm geometry, page state and the same guest are restored.
6. Choose Performance Fullscreen only with disposable pages. Confirm the warning,
   unload, resume reload, and absence of unintended reloads in seamless mode.
7. Rotate, use a smaller host scene, background/foreground, reconnect a keyboard,
   and test Reduce Motion/Transparency. Check existing signing/refresh features.

Measure CPU, memory, frame pacing and power on the device before making savings
or emulator-performance claims. Private guest surface hosting/focus requires
real hardware; neither Linux tests nor simulator rendering establishes it.

## Remaining system work

- Downloads, bookmarks/pinned web apps, browser permission dialogs and richer
  browser controls; persisted workspace restoration and crash recovery.
- Full Tahoe visual pass, real window thumbnails in overview, more menus and
  shortcuts, contextual desktop actions, richer Finder operations.
- Guest focus/rotation/input fixes found during the first hardware test, then
  JIT emulator validation and measured resource policies.
- iPhone second workspace: independent-canvas capture/stream/input proof first,
  browser transport second, guest capture only if proven feasible. No remote
  display functionality or capture compatibility is claimed by this milestone.

LiveContainer retains its AGPL-3.0 licence; other bundled components retain their
existing licences. MIT notices travel in the framework and source notices. The
build includes the desktop source and applied runtime diff for review, with
the exact integration revision and upstream source/build references.
