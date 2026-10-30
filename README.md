# Tidest

**English** · [简体中文](README.zh-CN.md)

A macOS menu bar app for switching between individual windows, arranging them on screen, and keeping frequently used windows within reach.

Choose the exact window you need, including several windows from the same app or different folders open in Finder.

The release workflow builds Developer ID signed, Apple notarized packages with verifiable build provenance for immutable GitHub releases. See [release setup and download verification](docs/RELEASING.md) for setup requirements and verification commands.

## Features

- **Switch windows:** browse horizontal previews or a scrollable tile view using the keyboard, trackpad, or mouse.
- **Window positioning:** place the window under your pointer in a half, quarter, or the full available screen area.
- **Quick layout:** open a translucent fullscreen overlay, split regions directly on your screen, drag shared dividers, choose windows, and apply together.
- **Window Dock:** keep windows at either screen edge, reorder them, and choose which ones stay available after closing.
- **Make it yours:** customize shortcuts and choose English, Simplified Chinese, Traditional Chinese, Japanese, or Korean. Quick layout defaults to Option + Shift + Q.

## Get started

Open Tidest and follow the permission guide. Accessibility lets Tidest bring your chosen window forward and arrange it on screen. Screen Recording is optional and enables window previews.

| Action | Default shortcut |
| --- | --- |
| Switch windows | Option + Tab |
| Window positioning | Option + Q |
| Quick layout | Option + Shift + Q |
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

### Window positioning

Press **Option + Q**, then point at a visible part of the window you want to arrange. Click a layout or press its number:

| 1 · Top left | 2 · Top half | 3 · Top right |
| --- | --- | --- |
| 4 · Left half | 5 · Fill screen | 6 · Right half |
| 7 · Bottom left | 8 · Bottom half | 9 · Bottom right |

Corners use a quarter of the screen. Layouts use the available area on the screen under your pointer, leaving room for the menu bar and macOS Dock.

The panel stays open after you release Option. Press Esc or click outside to cancel.

### Quick layout

Press **Option + Shift + Q** to open a translucent fullscreen overlay. Customize the shortcut in **Settings → Windows**. The menu bar shows the current shortcut as a non-clickable reminder. If you clear the shortcut, set one again in Settings to open Quick layout. Existing Option + Q and custom positioning shortcuts keep their behavior.

1. Regions appear directly on the display under your pointer, starting with two columns. The upper-left toolbar shows thumbnails for a blank layout, four starting layouts, and saved templates. Hover to see names and scroll horizontally when needed. To use another display, close Quick layout, move your pointer there, and reopen it.
2. Move near a shared divider to reveal a circular drag handle and highlight its line. The handle follows your pointer along the divider and shows two arrows separated by a dashed line. Drag to resize regions while keeping the usable screen area filled. Split buttons take priority in their nearby areas. Buttons on horizontal edges split a region into rows; buttons on vertical edges split it into columns.
3. Hover over a region to highlight it. Soft guides mark the midpoint of each edge. Moving near a guide reveals its split button in a rounded inward curve; moving away retracts it. The original straight border stays visible. Buttons brighten on hover and respond when pressed. When splitting, a light at the curve’s tip separates into two points that follow the existing curve and border to its ends. Only then does the button retract and the new divider move into position. The new cards then fade in. The delete button fades in and out at the upper right of the central card. Click the region to open its window picker. Search by app or window title, use arrow keys and Enter to select, or Esc to close the picker. Each window can occupy only one region.
4. Once every region has a valid window, click **Apply** near the upper left or press **Enter** once to arrange and reveal all selected windows. **Cancel** and **Apply** form a separate group beside the original toolbar. **Cancel** or **Esc** discards the draft. Enter in the picker only selects its window; release the key and press Enter again to apply the layout.
5. **Reset**, **Save as template**, and **Revert** appear as icons beside the layout thumbnails, with names on hover. **Reset** restores the default two columns and clears the draft's window choices. **Revert** tries to restore the window positions from before the last application; it is disabled when there is nothing to restore.

Hovering over a window starts a snapshot immediately and shows it beside the picker after 120 ms. Arrow keys also update the preview, with a crossfade between windows. The 320 × 240 pt preview preserves the window's proportions, stays vertically centered beside the picker with a 12 pt gap, and uses the left side when the right side has insufficient room. Snapshots are reused throughout the current Quick Layout session, including list refreshes and choosing windows for other regions. Closing Quick Layout releases the cache asynchronously. Windows without a snapshot remain selectable.

Drag the central card of a region onto another region to swap window choices, or to the left, right, top, or bottom screen edge to move the whole region. The remaining regions expand to fill the space. Empty regions can move too, and window choices stay with moved regions. A preview shows the result before release; releasing outside the layout cancels. Moving the large left region to the right keeps its width and the two small regions' top-to-bottom order. When changing direction, a region that previously spanned the whole dimension takes half the space. Arrangements with insufficient space do not accept the drop.

Hover over an assigned region to reveal **Clear window choice**, which clears only that region's choice while preserving the region. Use **Delete region** to remove the region itself. The adjacent region or group expands to fill the space, preserving the remaining window choices. The final region cannot be deleted.

Editing, choosing windows, resetting, and saving templates leave real windows in place. Esc in the main preview cancels. Clicking an edge’s split button adds an empty region on that side and keeps the original window in the opposite half, without confirmation. Changing layouts or templates asks before clearing existing window choices; ratio changes retain assignments.

**Save as template** suggests an available name such as “Template 1”, which you can change. If the layout matches a starting layout or a saved template, its thumbnail is highlighted and a brief message appears instead of saving another copy. Templates store only a name, split structure, and normalized ratios, excluding apps, windows, titles, paths, and display identities. Right-click a template thumbnail in the toolbar to rename or delete it. Splitting depends on the actual usable screen area; delete a region or drag a divider when regions are too small.

Candidates are movable, resizable standard windows on the current desktop, including connected displays. Minimized windows, native fullscreen windows, other Spaces, and Tidest panels are excluded. App icons and titles work without Screen Recording permission.

Before applying, Tidest rechecks window identity, permissions, display configuration, and any reported minimum size. Unreported application limits are checked after execution. Operations can partially succeed; results identify each window, and **Retry failed windows** touches only failures. Full success closes preview; reopen Quick layout with its shortcut and choose **Revert** from the toolbar to restore the previous positions. Partial results also allow **Revert** from the toolbar. Revert tries to restore the last changed windows and never reopens closed ones. A new application replaces the previous restoration record.

Disconnecting or reconfiguring displays stops further placement and requires explicit target confirmation. Undo blocks stale coordinates after a display configuration change. See the [macOS validation checklist](docs/QUICK_LAYOUT_VALIDATION.md) for remaining platform verification.

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

Open **How to use** from the menu bar for animated examples of window switching, window positioning, Quick layout, and the Window Dock, using your current shortcuts. Pause, replay, drag the progress bar, or click a step to inspect it. Seeking pauses at that position; choose **Resume** to continue. With macOS **Reduce motion** enabled, drag the bar or choose a static step instead. Reading the guide does not require permissions.

**Settings → Windows** contains preview styles, shortcuts, and the Window Dock toggle. **Settings → General** contains language and permission settings. Tidest follows your system language until you choose one, and applies changes immediately.

In the menu bar, **Usage Statistics** sits below **How to use** and shows today's uses, all-time uses, and a seven-day bar chart. Hover over the chart to highlight a day and see its count. The info button explains the counting rules: each successful window switch, window positioning, complete Quick layout, dock addition, or opening from the dock counts once; canceled or failed actions and simply opening a panel do not count. Counting starts when a version with statistics first launches; earlier usage cannot be recovered.

| Permission | Purpose |
| --- | --- |
| Accessibility · Required | Switch, move, and resize windows |
| Screen Recording · Optional | Show window screenshots in the switcher and dock |
| Automation · Per app | Save and reopen folders, terminal directories, and browser tabs for kept windows |

Without Screen Recording, Tidest shows app icons and window titles; switching, positioning, and Quick layout remain available. Choose **Not now** to continue, and **Don't remind me again** to stop future reminders.

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
| Window positioning | `--ui-preview-layout`; optionally `--ui-preview-layout-constrained` |
| Multi-window Quick layout | `--ui-preview-multi-layout`; optionally `--ui-preview-multi-layout-partial` for partial failure feedback |
| Window Dock | `--ui-preview-pinned`; optionally `--ui-preview-count=20` |
| Preview language | `--ui-preview-language=<code>`, where code is `en`, `zh-Hans`, `zh-Hant`, `ja`, or `ko` |
| Enabled permissions in Settings preview | `--ui-preview-granted-accessibility` and `--ui-preview-granted-screen` |

## License

Unless otherwise noted, the source code, documentation, and assets in this repository are licensed under **Apache License 2.0**. See [LICENSE](LICENSE) for the full terms and [NOTICE](NOTICE) for copyright and licensing notices.
