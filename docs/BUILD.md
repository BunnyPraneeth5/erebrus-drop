# Building Erebrus Drop

## Mobile (Android / iOS)

The project uses `String.fromEnvironment` for build-time configuration, so
values in `.env` must be passed as `--dart-define` flags. Copy the example file
and fill in any missing values, then use the provided wrapper so `.env` is
injected automatically:

```bash
cp env.example .env
flutter pub get
scripts/build.sh run                              # Android debug (playstore flavor default)
scripts/build.sh build-appbundle --release        # Google Play (playstore flavor default)
scripts/build.sh build-apk --flavor dappstore --release         # Solana dApp Store
```

Environment variables:

- `REOWN_PROJECT_ID` — required for wallet/social login.
- `GATEWAY_URL` — Erebrus gateway base URL (default `https://gateway.erebrus.io`).
- `IPFS_GATEWAY_URL` — public IPFS gateway for CID downloads (default `https://ipfs.erebrus.io`).
- `REDDIT_CLIENT_ID` — optional Reddit "installed app" client ID used by Grab for Reddit posts.

`scripts/build.sh build-apk` and `build-appbundle` default to the `playstore`
flavor when no `--flavor` is given.

If you prefer to run `flutter` directly, pass the whole file and an explicit
flavor for APK / AppBundle builds:

```bash
flutter run --dart-define-from-file=.env
flutter build apk --dart-define-from-file=.env --flavor playstore --release
flutter build apk --dart-define-from-file=.env --flavor dappstore --release
```

**Android Studio / IntelliJ:** add `--dart-define-from-file=.env` to the run
configuration’s **Additional run args**. For the **Build APK** action also
include a flavor, e.g. `--dart-define-from-file=.env --flavor playstore` or
`--flavor dappstore`.

Signing: copy `android/key.properties.example` → `android/key.properties`.  
See [solana-dapp-store-release.md](solana-dapp-store-release.md).

## Desktop (macOS / Windows / Linux)

Erebrus Drop ships as a Flutter desktop app on all three platforms. Shared Dart
code drives the UI, tray, window sizing, responsive layout, mDNS discovery,
folder library, and in-app About/Privacy/Terms.

Native pieces differ only where the OS requires it, including macOS sandboxed
folder access and each desktop platform's `erebrusdrop://` browser callback
registration and running-instance delivery.

### Prerequisites

| Platform | Requirements |
|----------|----------------|
| **macOS** | Flutter stable, Xcode command-line tools |
| **Windows** | Flutter stable, Visual Studio with C++ desktop workload |
| **Linux** | Flutter stable, `clang`, `cmake`, `ninja-build`, GTK 3 dev packages |

Run `flutter doctor` and enable the desktop platform you target.

### Brand assets (run before desktop release builds)

```bash
python3 scripts/generate-desktop-assets.py
```

This script:

| Output | Used for |
|--------|----------|
| `assets/images/erebrus-tray*.png` | System tray (all desktop) |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/` | Dock icon |
| `macos/Runner/Assets.xcassets/AboutIcon.imageset/` | Menu bar **About** panel (glossy, no black border) |
| `windows/runner/resources/app_icon.ico` | Taskbar / window icon |
| `linux/runner/resources/app_icon.png` | Taskbar / window icon |

It also runs `dart run flutter_launcher_icons` for mobile launcher icons from
`assets/images/erebrus-glossy.png`.

Re-run after any change to `erebrus-glossy.png` or `erebrus-glyph.png`.

### Dev

```bash
flutter pub get
python3 scripts/generate-desktop-assets.py   # first time or after logo changes
scripts/build.sh run -d macos      # or windows / linux
```

### Release

`scripts/build-desktop.sh` runs asset generation automatically, then builds and
packages:

```bash
./scripts/build-desktop.sh macos
./scripts/build-desktop.sh windows    # on Windows
./scripts/build-desktop.sh linux      # on Linux
./scripts/build-desktop.sh all        # macOS host; skips Win/Linux if unavailable
```

Artifacts land in `dist/`:

| Output | Contents |
|--------|----------|
| `erebrus-drop-macos-v*.zip` | `.app` bundle |
| `erebrus-drop-windows-v*.zip` | `Release/` folder with `.exe` |
| `erebrus-drop-linux-v*.tar.gz` | `bundle/` directory |

### Desktop feature parity

| Feature | macOS | Windows | Linux |
|---------|-------|---------|-------|
| System tray + hide on close | ✓ | ✓ | ✓ |
| Window default 880×820, min 720×640 | ✓ | ✓ | ✓ |
| Responsive layout + side rail | ✓ | ✓ | ✓ |
| mDNS nearby rooms (Bonsoir) | ✓ | ✓ | ✓ |
| Folder library / file ops | ✓ | ✓ | ✓ |
| Browser sign-in callback | ✓ | ✓ | ✓ |
| Apple sign-in | ✓ | — | — |
| In-app About / copyright | ✓ | ✓ | ✓ |
| Launcher / taskbar icon | ✓ | ✓ | ✓ |
| Menu bar About (native) | ✓ | — | — |

### Desktop notes

- **Hosting:** local HTTP server binds on the LAN; allow incoming connections in the OS firewall if prompted.
- **Folders:** macOS uses a directory-only `NSOpenPanel`, stores a security-scoped bookmark, restores it on later launches, and holds access only while the folder is selected. The Mac App Store sandbox uses **User Selected File: Read/Write**; broad Downloads-folder access is not required.
- **Browser sign-in:** all desktop builds register `erebrusdrop://`. A callback launches the app when closed or is forwarded to and focuses the existing app instance when already running. The paste-token action remains a recovery fallback.
- **Authentication:** macOS shows Apple sign-in above the browser action only when the gateway advertises `apple: true`. All desktop and mobile sign-in screens can return to the pushed main app route as a guest.
- **Wallet:** Solana Mobile Wallet features are Android-only by design.
- **QR scan:** hidden on desktop; use manual join or Drop Link.

## Verify

```bash
flutter analyze
flutter test
```

## GitHub Release workflow

CI desktop jobs call `scripts/build-desktop.sh` (macOS/Linux) or
`scripts/generate-desktop-assets.py` + `flutter build windows` (Windows).
GitHub Release steps: **Actions → Release → Run workflow** (see README release checklist).
