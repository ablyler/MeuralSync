# Changelog

All notable changes to **MeuralSync** are documented in this file.

## v1.0.22

- Added a **Once a Day (Retry Until Synced)** schedule frequency, ported from the osxphotos2meural launchd job: syncs at the first chance each day and retries every hour until a sync succeeds, with no retry cap. Any successful sync (manual or scheduled) counts toward the day.
- Added **Allowed From / Allowed Until** times for this frequency to limit when syncing may run. Equal times allow the whole day, and an end earlier than the start wraps past midnight (for example, 22:00–06:00).
- Added **Gallery Mode** per instance: choose between **Create & Delete Gallery** (rolling galleries) or **Update Existing Gallery** (replaces photos in a chosen Meural gallery without deleting it).
- Added **Photo Selection Mode** per instance: choose between **People** filtering or syncing directly from an Apple Photos **Album**.
- Made saved Keychain passwords unmistakable in Settings with a green **Saved** badge and clear prompt, and right-aligned all instance setting values.

## v1.0.21

- Hid the **On Frame / All** filter and skipped frame-specific badges (`Showing`, detected orientation) in **Meural Galleries** when the selected instance has no Meural frame linked, showing all account albums directly.

## v1.0.20

- Added `CHANGELOG.md` and embedded Sparkle release notes so the macOS Software Update dialog displays what changed whenever an update is available.
- GitHub Releases now use the matching `CHANGELOG.md` section (with automatic git-commit fallback if an entry is omitted).

## v1.0.19

- Prevented toolbar button labels in **Meural Galleries** (`Send to Frame`, `Delete Album`, `Clean Up Unused`, `Refresh`) from truncating by adding `.fixedSize()` and an adaptive two-row fallback layout when the window is narrower.
- Widened the default **Meural Galleries** window size to `1020×640`.

## v1.0.18

- Disabled **Send to Frame** in the Galleries toolbar and sidebar context menu when no target Meural frame is selected for that instance.
- Clarified the Target Meural Frame picker in Settings with an explicit unselected option (`None (Select a Frame)`), reminder text, and automatic single-frame selection.

## v1.0.17

- Added a **Target Meural Frame** picker per instance in Settings (shown when **Push & Switch Devices** is enabled) so multi-frame accounts can target a specific frame.
- Scoped orientation auto-detection, sync pushes, retry pushes, and **Send to Frame** to the selected frame.

## v1.0.16

- Displayed the live unassigned photo count and total file size directly on the **Clean Up Unused** button (e.g., `Clean Up Unused (14 · 31.2 MB)`) and in its confirmation dialog.

## v1.0.15

- Added a **Clean Up Unused** button in the Galleries window to delete photos on the logged-in Meural account that do not belong to any album.

## v1.0.14

- Highlighted the album currently playing on the Meural frame with a green **Showing** badge and sorted it to the top of the sidebar.
- Added a **Delete Album & All Photos** option alongside **Delete Album (Keep Shared Photos)** in the delete confirmation dialog.

## v1.0.13

- Silently re-verified PhotoKit authorization on launch for previously authorized installs so Sparkle updates no longer flash a false "Grant Photos Access" banner.

## v1.0.12

- Hardened multi-instance sync so one failing instance does not abort remaining instances.
- Guarded orphan photo cleanup when any gallery omits `itemIds` metadata.
- Fixed EXIF `.leftMirrored` / `.rightMirrored` rotation clipping on non-square photos.

## v1.0.11

- Protected fallback galleries when a frame push fails and recorded uploaded item IDs immediately after creation.
- Made Keychain vault updates atomic and fail-closed on corrupt JSON.
- Serialized frame push retries against sync and gallery mutations.

## v1.0.10

- Fixed Swift 6.0/6.1 CI compatibility for the shared `CIContext`.

## v1.0.9

- Upgraded photo captions to a frosted Gaussian-blur glass pill with left-aligned two-row layout, park/ride icons, and configurable date format.

## v1.0.8

- Filtered the **Meural Galleries** sidebar to albums loaded on the frame by default (`On Frame` / `All` toggle).
- Added Portrait (`1080×1920`) and Landscape (`1920×1080`) frame orientation support with auto-detection and symmetric 2-up photo pairing.

## v1.0.7

- Persisted failed frame pushes across launches and added a one-click **Retry** banner in the menu bar popover.

## v1.0.6

- Added a **Follow** toggle to the Logs window and restricted the Dock icon to show only while an app window is open.

## v1.0.5

- Consolidated Keychain credentials across all instances into a single cached item with prompt-free existence checks and automatic legacy migration.

## v1.0.4

- Fixed a release `.app` bundle crash when locating SwiftPM resource bundles (`Captions.resourceBundle`).

## v1.0.3

- Updated the menu bar icon to match the custom portrait-frame app icon.

## v1.0.2

- Added custom macOS `AppIcon.icns` and vector source.

## v1.0.1

- Fixed code signing for the data-only SwiftPM resource bundle on macOS 15 CI runners.

## v1.0.0

- Initial public release of MeuralSync with PhotoKit sync, Meural Galleries browser, custom captions & icons, and Sparkle 2 auto-updates.
