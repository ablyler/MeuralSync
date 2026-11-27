# MeuralSync

A native macOS menu bar app (Swift + SwiftUI) that syncs curated photos from your macOS Photos library to Meural digital frames.

## Features

- **Native macOS Menu Bar App** (`MenuBarExtra`) with an animated sync status icon, live sync progress, log viewer, interactive Caption Preview, and built-in **Meural Galleries & Photos browser** (inspect albums/photos, send any album to your frame, or delete albums/photos safely)
- **Native PhotoKit Integration**:
  - Uses Apple's `PhotoKit` (`PHAsset`, `PHImageManager`) for library enumeration, screenshot/hidden/trashed filtering, curation scores, and automatic iCloud photo downloads — **no Full Disk Access required** for normal syncs
  - On-demand cached reverse geocoding (`CLGeocoder`) for selected photos
  - Optional read-only `Photos.sqlite` People enrichment when Full Disk Access is granted (needed if you use People filters or People names in captions)
- **Native Core Graphics & Core Text Image Pipeline**:
  - EXIF auto-orientation, portrait 1080×1920 fill, paired landscape 1080×1920 vertical stacking
  - Translucent caption overlays with configurable person & location aliases, first-name shortening, US location cleanup, and 38 original bundled vector park/attraction icons (`.svg` + `.png`, plus local override support in `~/Library/Application Support/MeuralSync/icons/`)
- **Native Meural API & AWS Cognito Client** (`URLSession` + `async/await`):
  - Direct AWS Cognito `USER_PASSWORD_AUTH` with transient retries and automatic 401 token refresh
  - Safe ownership-tracked gallery & orphan cleanup that protects user-owned albums and shared photos
  - macOS Keychain credential storage (`Security.framework`) keyed by stable instance UUID
- **Flexible Scheduling, Wake Catch-Up & Launch at Login** (`SMAppService`)
- **Auto-Updates via Sparkle 2** (EdDSA-verified GitHub Releases + `appcast.xml`)

## Requirements

- macOS 14.0+ (Sonoma or newer, Apple Silicon)
- **Photos Library permission** (required for `PhotoKit`)
- **Full Disk Access** *(optional — only needed if you use People include/exclude filters or People names in captions)*

## Install (Recommended)

Download the latest signed release from [GitHub Releases](https://github.com/ablyler/MeuralSync/releases/latest) (includes automatic in-app updates via Sparkle 2):

1. Download `MeuralSync-vX.Y.Z.zip` from the [Latest Release](https://github.com/ablyler/MeuralSync/releases/latest) and unzip it.
2. Move `MeuralSync.app` into `/Applications`.
3. Because the release is not Apple-notarized, remove macOS's quarantine flag once before first launch:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MeuralSync.app
   open /Applications/MeuralSync.app
   ```

Or install in one step from Terminal:

```bash
curl -fsSL "$(curl -fsSL https://api.github.com/repos/ablyler/MeuralSync/releases/latest | grep -o '"browser_download_url": *"[^"]*\.zip"' | cut -d'"' -f4)" -o /tmp/MeuralSync.zip \
  && rm -rf /Applications/MeuralSync.app \
  && ditto -x -k /tmp/MeuralSync.zip /Applications/ \
  && rm -f /tmp/MeuralSync.zip \
  && xattr -dr com.apple.quarantine /Applications/MeuralSync.app \
  && open /Applications/MeuralSync.app
```

Future updates install automatically in-app (**Menu Bar → Updates…** or **Settings → General → Check for Updates…**).

## Build from Source

Requires Xcode / Swift 6.0+.

```bash
# Run unit & Core Graphics integration tests
swift test

# Build release MeuralSync.app bundle
chmod +x scripts/build_app.sh
./scripts/build_app.sh

# Install to /Applications
pkill -x MeuralSync 2>/dev/null || true
rm -rf /Applications/MeuralSync.app
cp -R dist/MeuralSync.app /Applications/
open /Applications/MeuralSync.app
```

You can also open `Package.swift` directly in Xcode.

## First-Time Setup

1. Launch **MeuralSync** (appears in the menu bar).
2. Grant **Photos Library** access when prompted (or in **Settings → General**). If you want People filtering/captions, also grant optional **Full Disk Access**.
3. Open **Settings → Instances** and add an instance (or click **Import config.json…**), enter your Meural email/password (stored in macOS Keychain), and click **Test Connection**.
4. Optionally enable **Launch at Login** and **Scheduled Sync** in **Settings → General**.

### Optional `config.json` Aliases

You can customize person and location display names per instance in `~/Library/Application Support/MeuralSync/config.json`:

```json
"caption_person_aliases": {
  "Robert Smith": "Grandpa"
},
"caption_location_aliases": {
  "123 Main St, Anytown": "Home"
}
```

## Publishing Releases with Sparkle 2 Auto-Updates

1. Generate a Sparkle EdDSA keypair once (using Sparkle's `generate_keys` tool):
   - Add the **public** key as GitHub Actions secret `SPARKLE_PUBLIC_ED_KEY`.
   - Add the **private** key as GitHub Actions secret `SPARKLE_PRIVATE_ED_KEY`.
2. Push a version tag:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
   The [Release workflow](.github/workflows/release.yml) builds `MeuralSync.app`, signs the archive, generates `appcast.xml`, and publishes both to GitHub Releases.

## License

MIT — see [LICENSE](LICENSE).
