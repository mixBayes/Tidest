# Tidest

**English** · [简体中文](README.zh-CN.md) · [Website](https://tidest.app/en/) · [Download](https://tidest.app/en/download/) · [Mac Window Managers Compared](https://tidest.app/en/guides/free-mac-window-managers/)

Tidest is a free, open-source macOS window manager for switching, arranging, and docking windows.

Choose individual windows, arrange them on screen, and keep frequently used folders and tabs within reach. Runs natively on Apple silicon and Intel Macs with macOS 14 Sonoma or later.

## Features

- **Switch windows:** browse horizontal previews or a scrollable tile view using the keyboard, trackpad, or mouse.
- **Single-window layout:** place the window under your pointer in a half, quarter, or the full available screen area.
- **Combined layout:** open a translucent fullscreen overlay, split regions directly on your screen, drag shared dividers, choose windows, and apply together.
- **Dock window:** keep previews at either screen edge. Enable **Keep** to reopen closed Finder folders, macOS Terminal directories, and Safari or Chrome tabs.
- **Make it yours:** customize shortcuts and choose English, Simplified Chinese, Traditional Chinese, Japanese, or Korean. Combined layout defaults to Option + Shift + Q.

## Get started

Open Tidest and follow the permission guide. Accessibility lets Tidest bring your chosen window forward and arrange it on screen. Screen Recording is optional and enables window previews.

| Action | Default shortcut |
| --- | --- |
| Switch windows | Option + Tab |
| Single-window layout | Option + Q |
| Combined layout | Option + Shift + Q |
| Dock window | Option + W |

Change shortcuts in **Settings → Windows**. Click the current combination, hold Control, Option, or Command, then press another key; Shift may be added. Press Esc to cancel. If a shortcut is already in use, Tidest keeps the previous combination. The menu bar shows your current shortcuts.

### Switch windows

1. Hold **Option** and press **Tab** to open the switcher.
2. Keep Option held and press Tab to select the next window. Hold both keys to advance about once per second.
3. Release Option to bring the selected window forward.

Click a preview to switch immediately. Press Esc or click outside the panel to cancel.

**Horizontal preview:** swipe left on a trackpad or Magic Mouse for the next window, or right for the previous one. A regular mouse wheel moves forward when scrolled down and backward when scrolled up.

**Tile preview:** hover over a preview to select it, and scroll vertically to see more windows. Keyboard selection scrolls offscreen windows into view.

Windows follow their front-to-back order on the current desktop. Minimized windows are restored when selected. Each preview keeps the window's proportions, and refreshes preserve your selection and scroll position.

### Single-window layout

Press **Option + Q**, then point at a visible part of the window you want to arrange. Click a layout or press its number:

| 1 · Top left | 2 · Top half | 3 · Top right |
| --- | --- | --- |
| 4 · Left half | 5 · Fill screen | 6 · Right half |
| 7 · Bottom left | 8 · Bottom half | 9 · Bottom right |

Corners use a quarter of the screen. Layouts use the available area on the screen under your pointer, leaving room for the menu bar and macOS Dock.

The panel stays open after you release Option. Press Esc or click outside to cancel.

### Combined layout

Press **Option + Shift + Q** to arrange several windows together. The layout opens on the screen under your pointer; to use another display, close it, move your pointer there, and reopen it.

1. Choose a starting layout or a saved template from the toolbar.
2. Split regions using their edge buttons, and drag shared dividers to adjust their sizes. A split adds an empty region on the clicked side and keeps the existing window on the other side.
3. Click each region to choose a window. Search by app or title, then use the arrow keys and Enter, or click a window. Hover or move the keyboard selection to see a preview. Each window can be chosen once.
4. Drag a region’s central card onto another to swap their window choices, or to a screen edge to move the region. **Clear window choice** keeps the region; **Delete region** removes it and lets its neighbors fill the space.
5. When every region has a window, click **Apply** or press **Enter** to arrange and reveal them together. Enter inside the picker only chooses a window; release it and press again to apply. **Cancel** or **Esc** discards the draft without moving real windows.

**Reset** starts over with two empty columns. **Revert** tries to restore positions from the last application; it does not reopen closed windows. Windows with size limits are placed as close as possible to the target, while windows that cannot be operated are skipped so the others can continue. If the display configuration changes, reopen the layout on the intended screen.

**Save template** stores the layout’s name, split structure, and proportions. Duplicate layouts are highlighted instead of saved again. Right-click a saved template to rename or delete it. Changing layouts asks before clearing existing window choices.

**Save current group** saves the layout and its window choices as one kept dock item. Clicking it restores the group, using the dock’s supported reopening behavior for closed windows. Groups survive Tidest restarts. Saving a template or group leaves real windows in place.

Combined layout uses movable, resizable windows on the current desktop, including connected displays. Minimized windows, native fullscreen windows, other Spaces, and Tidest panels are excluded. Without Screen Recording permission, app icons and titles remain available. Animations respect macOS **Reduce Motion**.

Preview timing, animation details, geometry rules, and platform checks are documented in the [implementation and validation notes](docs/QUICK_LAYOUT_VALIDATION.md).

### Dock window

The dock is enabled by default on the right side of the screen.

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

Open **How to use** from the menu bar for animated examples of **Switch windows**, **Single-window layout**, **Combined layout**, and **Dock window**, using your current shortcuts. Pause, replay, drag the progress bar, or click a step to inspect it. Seeking pauses at that position; choose **Resume** to continue. With macOS **Reduce motion** enabled, drag the bar or choose a static step instead. Reading the guide does not require permissions.

**Settings → Windows** contains preview styles, shortcuts, and the **Dock window** toggle. **Settings → General** contains language and permission settings. Tidest follows your system language until you choose one, and applies changes immediately.

In the menu bar, **Usage Statistics** sits below **How to use** and shows today's uses, all-time uses, and a seven-day bar chart. Hover over the chart to highlight a day and see its count. The info button explains the counting rules: each successful window switch, single-window layout, complete Combined layout, dock addition, or opening from the dock counts once; canceled or failed actions and simply opening a panel do not count. Counting starts when a version with statistics first launches; earlier usage cannot be recovered.

| Permission | Purpose |
| --- | --- |
| Accessibility · Required | Switch, move, and resize windows |
| Screen Recording · Optional | Show window screenshots in the switcher and dock |
| Automation · Per app | Save and reopen folders, terminal directories, and browser tabs for kept windows |

Without Screen Recording, Tidest shows app icons and window titles; switching, positioning, and Combined layout remain available. Choose **Not now** to continue, and **Don't remind me again** to stop future reminders.

Tidest checks permissions when it starts or is reopened. Use **Open System Settings** in General to manage them. macOS asks for Automation permission separately when Tidest reads or controls a supported app.

## Local data and privacy

Tidest checks the signed GitHub update feed in the background every 24 hours, using the last check time across restarts. A new version adds a small upgrade mark to the menu-bar icon and the About menu item, plus a clickable reminder shown once per version on this Mac. Background checks do not open About or show update dialogs, and failures do not interrupt your work. Clicking the reminder opens About with the known version and a **Download** button; opening About again uses the saved update information without another check. The upgrade marks remain after dismissing the reminder or viewing About and disappear after the update is installed.

Choose **Download** to download inside Tidest with progress and cancellation. Sparkle revalidates the offered update when you choose to download it. Once it is ready, choose **Restart and update** or **Later**. Later keeps the current version running; you can restart from About, or let the update finish when you next quit Tidest. Closing About does not cancel a download. Update failures do not prevent you from using the current version. About and update checks do not require Accessibility permission or send your settings or window records.

Updates use [Sparkle 2](https://sparkle-project.org/). Its installer and relaunch helper are bundled inside Tidest; there is no separate application to install. macOS may ask for administrator authorization if the installation location requires it. Versions without the in-app updater need one manual installation before they can use this flow.

Tidest stores its settings, window records, and usage counts on your Mac. Release builds send anonymous daily activity information to PostHog by default to understand how many installations use Tidest each day. Turn this off in **Settings → General → Send anonymous usage information**.

Activity is recorded only when you open a panel or interact with Tidest; running in the background does not count. At most one successful report is sent per day in the Asia/Shanghai time zone. A random installation ID stored on your Mac survives restarts; separate Macs count separately. Reports contain only that ID, the interaction time, and the app version, without window titles, screenshots, file paths, or browser URLs. They do not create person profiles or infer location from IP addresses. Failed reports never interrupt your work; another interaction after a minute can retry. Entirely offline days are not uploaded later. Development builds, tests, and UI previews do not send data to the live project.

- **Switcher previews** stay in memory and are cleared when Tidest quits.
- **Docked windows** save their app, title, window identity, dimensions, order, and last preview across restarts.
- **Kept windows** also save supported Finder folders, Terminal directories, or browser tab URLs.
- **Preferences and window records** use macOS `UserDefaults`, the system's local settings storage.
- **Usage counts** store only daily totals and the counting start date, with no action history or uploads.
- **Daily activity markers** store the random installation ID and the most recent successfully reported Beijing calendar date locally to avoid duplicate reports across restarts.
- **Dock previews** are PNG files in `~/Library/Application Support/com.mixbayes.tidest/PinnedPreviews/`. Removing an item deletes its corresponding preview.

Saved previews can contain window contents, and browser URLs can include query parameters. Keep this in mind when sharing screenshots, preferences, or diagnostic material.

## Build from source

The current project requires **macOS 14.0 or later**, as configured in `tidest.xcodeproj`, and Xcode with support for the macOS APIs used by the project. Xcode automatically resolves the pinned Sparkle 2.10.1 dependency.

Open `tidest.xcodeproj` in Xcode, select the `tidest` scheme, choose your own signing team if needed, and run.

For a local development build with an ad hoc signature:

```sh
xcodebuild -project tidest.xcodeproj -scheme tidest -configuration Debug \
  -derivedDataPath /tmp/tidest-build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

The app is built at `/tmp/tidest-build/Build/Products/Debug/tidest.app`.

Tidest uses SwiftUI and AppKit, with Accessibility for window control and ScreenCaptureKit for previews. App Sandbox is disabled to support controlling other apps' windows; Hardened Runtime remains enabled. Public distribution requires a Developer ID signature and notarization.

The release workflow builds Developer ID-signed, Apple-notarized packages with verifiable build provenance for immutable GitHub releases. See [release setup and download verification](docs/RELEASING.md) for setup requirements and verification commands.

### Tests and UI previews

Tidest is a macOS app. Geometry, draft, controller, and UI tests run with Xcode on macOS:

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
| Single-window layout | `--ui-preview-layout`; optionally `--ui-preview-layout-constrained` |
| Combined layout | `--ui-preview-multi-layout`; add `--ui-preview-multi-layout-partial`, `--ui-preview-multi-layout-denied`, or `--ui-preview-multi-layout-size-limits` to check silent skipping |
| Dock window | `--ui-preview-pinned`; optionally `--ui-preview-count=20` |
| Preview language | `--ui-preview-language=<code>`, where code is `en`, `zh-Hans`, `zh-Hant`, `ja`, or `ko` |
| Enabled permissions in Settings preview | `--ui-preview-granted-accessibility` and `--ui-preview-granted-screen` |

## License

Unless otherwise noted, the source code, documentation, and assets in this repository are licensed under **Apache License 2.0**. See [LICENSE](LICENSE) for the full terms and [NOTICE](NOTICE) for copyright and licensing notices.
