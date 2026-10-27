# Tidest

**English** · [简体中文](README.zh-CN.md)

A macOS menu bar app for switching between individual windows, arranging them on screen, and keeping frequently used windows within reach.

Choose the exact window you need, including several windows from the same app or different folders open in Finder.

The release workflow builds Developer ID signed, Apple notarized packages with verifiable build provenance for immutable GitHub releases. See [release setup and download verification](docs/RELEASING.md) for setup requirements and verification commands.

## Features

- **Switch windows:** browse horizontal previews or a scrollable tile view using the keyboard, trackpad, or mouse.
- **Quick layout:** place the window under your pointer in a half, quarter, or the full available screen area.
- **Window Dock:** keep windows at either screen edge, reorder them, and choose which ones stay available after closing.
- **Make it yours:** customize all three shortcuts and choose English, Simplified Chinese, Traditional Chinese, Japanese, or Korean.

## Get started

Open Tidest and follow the permission guide. Accessibility lets Tidest bring your chosen window forward and arrange it on screen. Screen Recording is optional and enables window previews.

| Action | Default shortcut |
| --- | --- |
| Switch windows | Option + Tab |
| Quick layout | Option + Q |
| Pick Up Window | Option + W |

Change shortcuts in **Settings → Windows**. Click the current combination, hold Control, Option, or Command, then press another key; Shift may be added. Press Esc to cancel. If a shortcut is already in use, Tidest keeps the previous combination. The menu bar shows your current shortcuts.

### Switch windows

1. Hold **Option** and press **Tab** to open the switcher.
2. Keep Option held and press Tab to select the next window. Hold both keys to advance about once per second.
3. Release Option to bring the selected window forward.

Click a preview to switch immediately. Press Esc or click outside the panel to cancel.

**Horizontal preview:** swipe left on a trackpad or Magic Mouse for the next window, or right for the previous one. A regular mouse wheel moves forward when scrolled down and backward when scrolled up.

**Tile preview:** hover over a preview to select it, and scroll vertically to see more windows. Keyboard selection scrolls offscreen windows into view.

Windows follow their front-to-back order on the current desktop. Minimized windows are restored when selected. Each preview keeps the window's proportions, and refreshes preserve your selection and scroll position.

### Quick layout

Press **Option + Q**, then point at a visible part of the window you want to arrange. Click a layout or press its number:

| 1 · Top left | 2 · Top half | 3 · Top right |
| --- | --- | --- |
| 4 · Left half | 5 · Fill screen | 6 · Right half |
| 7 · Bottom left | 8 · Bottom half | 9 · Bottom right |

Corners use a quarter of the screen. Layouts use the available area on the screen under your pointer, leaving room for the menu bar and macOS Dock.

The panel stays open after you release Option. Press Esc or click outside to cancel.

### Window Dock

Window Dock is enabled by default on the right side of the screen.

1. Press **Option + W** to start picking up a window.
2. Click the highlighted window to pick up its preview. The original window stays where it is.
3. Move the preview to the dock and click again to place it.
4. Click a docked item to bring its window forward.

Press Esc or Option + W again to cancel picking up a window. The dock opens when the pointer reaches the chosen edge of any display and closes when the pointer leaves. All displays share one list; reaching the same edge on another display moves the dock there, even while it is still open.

- **Choose a side:** use the header's side button, or drag the header a short distance toward the center of the screen.
- **Choose a view:** switch between thumbnails and icons with titles using the header's display control.
- **Reorder:** drag items inside the dock.
- **Remove:** drag an item out and release, or choose **Remove from dock** from its context menu. Its window stays open.
- **Keep after closing:** enable the item's **Keep** pin. Click a closed item to reopen it.

All docked items, their order, and the chosen side survive a Tidest restart. Items without Keep enabled are removed when their original windows close. Dock animations follow the macOS **Reduce motion** setting.

| App | What a kept item reopens |
| --- | --- |
| Finder | A new window at the saved folder or Recents location |
| Terminal | A new window in the selected tab's saved local directory |
| Chrome / Safari | A new window with the saved tabs, tab order, and selected tab |
| Other apps | The app itself |

Saved folders, directories, and tabs follow changes while the window is open. Reopening uses the last successfully saved location.

## Settings and permissions

Open **How to use** from the menu bar for animated examples of window switching, quick layout, and the Window Dock, using your current shortcuts. Pause, replay, drag the progress bar, or click a step to inspect it. Seeking pauses at that position; choose **Resume** to continue. With macOS **Reduce motion** enabled, drag the bar or choose a static step instead. Reading the guide does not require permissions.

**Settings → Windows** contains preview styles, shortcuts, and the Window Dock toggle. **Settings → General** contains language and permission settings. Tidest follows your system language until you choose one, and applies changes immediately.

| Permission | Purpose |
| --- | --- |
| Accessibility · Required | Switch, move, and resize windows |
| Screen Recording · Optional | Show window screenshots in the switcher and dock |
| Automation · Per app | Save and reopen folders, terminal directories, and browser tabs for kept windows |

Without Screen Recording, Tidest shows app icons and window titles; switching and quick layout remain available. Choose **Not now** to continue, and **Don't remind me again** to stop future reminders.

Tidest checks permissions when it starts or is reopened. Use **Open System Settings** in General to manage them. macOS asks for Automation permission separately when Tidest reads or controls a supported app.

## Local data and privacy

Opening **About Tidest** automatically checks `https://tidest.app/api/update`. When a newer version is available, Tidest shows its version and asks whether to download it. Only choosing **Download** opens the installation-package link in your default browser. Install it after downloading. You can also check again manually. About and update checks do not require Accessibility permission. Update checks do not send your settings or window records.

Tidest stores its settings and window records on your Mac. The current app includes no analytics or upload service.

- **Switcher previews** stay in memory and are cleared when Tidest quits.
- **Docked windows** save their app, title, window identity, dimensions, order, and last preview across restarts.
- **Kept windows** also save supported Finder folders, Terminal directories, or browser tab URLs.
- **Preferences and window records** use macOS `UserDefaults`, the system's local settings storage.
- **Dock previews** are PNG files in `~/Library/Application Support/com.mixbayes.tidest/PinnedPreviews/`. Removing an item deletes its corresponding preview.

Saved previews can contain window contents, and browser URLs can include query parameters. Keep this in mind when sharing screenshots, preferences, or diagnostic material.

## Build from source

The current project requires **macOS 14.0 or later**, as configured in `tidest.xcodeproj`, and Xcode with support for the macOS APIs used by the project. No third-party package installation is needed.

Open `tidest.xcodeproj` in Xcode, select the `tidest` scheme, choose your own signing team if needed, and run.

For a local development build with an ad hoc signature:

```sh
xcodebuild -project tidest.xcodeproj -scheme tidest -configuration Debug \
  -derivedDataPath /tmp/tidest-build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

The app is built at `/tmp/tidest-build/Build/Products/Debug/tidest.app`.

Tidest uses SwiftUI and AppKit, with Accessibility for window control and ScreenCaptureKit for previews. App Sandbox is disabled to support controlling other apps' windows; Hardened Runtime remains enabled. Public distribution requires a Developer ID signature and notarization.

### Tests and UI previews

Run the test suites with:

```sh
xcodebuild -project tidest.xcodeproj -scheme tidest -configuration Debug \
  -derivedDataPath /tmp/tidest-build -destination 'platform=macOS' \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= test
```

The suites cover window selection, scrolling, shortcuts, settings and permissions, dock persistence and reopening, preview storage, and layout behavior.

Debug builds provide UI preview arguments for development. These previews use sample windows and separate settings, without requesting permissions or changing real windows.

| Preview | Arguments |
| --- | --- |
| Permission guides | `--ui-preview-accessibility` or `--ui-preview-screen` |
| Settings / About | `--ui-preview-settings` or `--ui-preview-about` |
| Usage guide | `--ui-preview-usage`; add `--ui-preview-usage-static` for static steps |
| Update states | `--ui-preview-about --ui-preview-update=<state>`, where state is `checking`, `up-to-date`, `available`, `failed`, or `download-failed`; uses sample responses and never opens a browser |
| Window switcher | `--ui-preview-switcher`; optionally `--ui-preview-tiled`, `--ui-preview-count=150`, `--ui-preview-thumbnails`, or `--ui-preview-refresh` |
| Quick layout | `--ui-preview-layout`; optionally `--ui-preview-layout-constrained` |
| Window Dock | `--ui-preview-pinned`; optionally `--ui-preview-count=20` |
| Preview language | `--ui-preview-language=<code>`, where code is `en`, `zh-Hans`, `zh-Hant`, `ja`, or `ko` |
| Enabled permissions in Settings preview | `--ui-preview-granted-accessibility` and `--ui-preview-granted-screen` |

## License

Unless otherwise noted, the source code, documentation, and assets in this repository are licensed under **Apache License 2.0**. See [LICENSE](LICENSE) for the full terms and [NOTICE](NOTICE) for copyright and licensing notices.
