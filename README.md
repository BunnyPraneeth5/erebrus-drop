# Erebrus Drop

Current version: `1.0.9+9`

Erebrus Drop is a local-first file and text sharing app for nearby devices. A
phone can create a temporary Drop Room on the current Wi-Fi network or hotspot,
and other devices can join from the mobile app or a browser without an account
or cloud upload.

[Get Erebrus Drop on Google Play](https://play.google.com/store/apps/details?id=com.erebrus.drop)

## What It Does

- Create a local Drop Room over Wi-Fi or hotspot.
- Discover nearby Drop Rooms with mDNS on Android and iOS.
- Share files, folders, text, and streamable media on the local network.
- Receive Android and iOS share-sheet text and files into Smart Send or a live room.
- Join from the app, a QR code, a Drop Link, or the bundled browser client.
- Download selected browser files or folders as ZIP bundles.
- Connect WebDAV clients to a live Drop Room through the `/dav` endpoint.
- Scan Drop Room QR codes with native Android and iOS camera scanners.
- Pull files from a joined room directly into a live hosted room.
- Use optional room passwords and scoped folder access.
- Save received files to the platform-appropriate user-visible location.
- Transfer directly on your local network, or explicitly use Erebrus nodes for global reach.

## App Surfaces

- Home: start or resume the current Drop Room.
- Rooms: discover and join nearby Drop Rooms.
- Library: view, share, and delete hosted files.
- Smart Send: send quick text into a room.
- Settings and About: app details, privacy, terms, and NetSepio ethos.

## What's New in 1.0.9+9

- **Burn Mode rooms now auto-expire** — rooms started with Burn Mode enabled shut down automatically at their two-hour deadline (previously the deadline was recorded but never enforced), and the host dashboard shows a live **"Expires in"** countdown. Enforcement also catches rooms whose deadline passed while the app was backgrounded, tearing them down on resume.
- **Redeem invite codes** — Settings now has an **Invite code** field to redeem a friend's referral code while signed in, so both of you are credited for the invite once you qualify.
- **True macOS menu-bar mode** — Erebrus Drop no longer occupies the Dock. Closing the window keeps the app running in the menu bar, whose tray icon is the sole way to reopen it; **Quit** remains available from the tray menu.
- **Corrected Google sign-in** — updated the Google server client ID used to verify Google sign-in tokens.

### Previously in 1.0.8+8

- **Reliable session expiry handling** — authenticated `401` responses now sign out once, clear persisted credentials, and explain that the session expired, while `403`, network, and server failures remain recoverable; stored sessions are revalidated on launch and resume.

### Previously in 1.0.7+7

- **Live room tray status** — the desktop tray icon is muted while idle and switches to the full adaptive black/white macOS glyph while a Drop Room is live.
- **Cleaner desktop sign-in** — browser sign-in is now the primary action; clipboard-token recovery appears only when the browser callback does not return automatically.
- **Clearer local and global sharing language** — onboarding, Home, Library, Smart Send, organization selection, and account status now describe nearby rooms and optional Erebrus node sharing consistently.
- **Desktop-first workspaces** — large Library and Smart Send views use split panes, the navigation rail shows live-room status, files can be dragged into Home or Send, and Cmd/Ctrl shortcuts cover tabs, refresh, and new rooms.
- **Persistent live Drop Rooms during sharing** — receiving a file through the Android or iOS share flow no longer treats Flutter UI recreation as a request to stop the active room.
- **Cleaner repository metadata** — macOS `.DS_Store` files are ignored throughout the repository.

### Previously in 1.0.6+6

- **Configurable IPFS gateway** — choose a preset (Erebrus, Cloudflare, Pinata, IPFS.io) or enter a custom gateway URL in Settings.
- **User-selected Drop folder** — all gateway downloads save to the folder you pick through the system file picker.
- **Persistent macOS folder access** — sandbox-safe security-scoped bookmarks preserve access to the selected Drop folder across launches.
- **Cleaner Settings** — removed the Solana dApp Store wallet card and the "Private by design" promo block.
- **Google and Apple sign-in** — native social login is available when enabled by the gateway, with Apple sign-in supported on iOS and macOS.
- **Reliable desktop browser sign-in** — `erebrusdrop://` callbacks return to the running app automatically on macOS, Windows, and Linux, including Google, Apple, and email accounts without a linked wallet; manual token paste remains available as a fallback.
- **Safer sign-in navigation** — every platform can return from the sign-in screen and continue as a guest if login is cancelled or fails.
- **Better wallet sign-in** — improved Solana Mobile Wallet and Reown message signing, waits for Reown readiness before enabling its action, and fixes the Erebrus Drop logo shown during wallet connection.
- **Safer sign-out** — signing out now requires confirmation and uses the existing Erebrus visual language.
- **Sign-in legal links** — both **Terms** and **Privacy Policy** are now linked on the sign-in screen.

## Release

Current release version:

```text
1.0.9+9
```

Android release versioning:

- The number after `+` is the Android `versionCode`.
- Google Play permanently reserves any uploaded `versionCode`, even if the
  draft/release is discarded.
- Always increase the `+` build number before uploading another AAB.

The Android package id is:

```text
com.erebrus.drop
```

Android uses two deploy flavors:

| Flavor | Output | Store |
|--------|--------|-------|
| `playstore` | AAB | Google Play |
| `dappstore` | APK | Solana dApp Store |

Both signing blocks live in one file:

```text
android/key.properties
```

Template:

```text
android/key.properties.example
```

Full signing and publish commands:

```text
docs/solana-dapp-store-release.md
```

Build commands:

```sh
# Debug Android defaults to playstore (no --flavor needed)
flutter run

# Google Play
flutter build appbundle --flavor playstore --release

# Solana dApp Store
flutter build apk --flavor dappstore --release
```

### Desktop (macOS / Windows / Linux)

Erebrus Drop ships on macOS, Windows, and Linux as well: system tray,
responsive layout, mDNS room discovery, folder library, automatic browser
authentication callbacks, and hide-to-tray on close.

**Generate brand assets** (tray icons, Dock/taskbar launcher icons, macOS
About icon, Linux window icon) before a desktop release build:

```sh
python3 scripts/generate-desktop-assets.py
```

This runs tray icon generation and `dart run flutter_launcher_icons` for
macOS/Windows/Android/iOS launcher icons from `assets/images/erebrus-glossy.png`.

**Dev:**

```sh
flutter pub get
python3 scripts/generate-desktop-assets.py   # first time or after logo changes
flutter run -d macos                       # or windows / linux
```

**Release bundles** (writes versioned artifacts under `dist/`):

```sh
./scripts/build-desktop.sh macos
./scripts/build-desktop.sh windows
./scripts/build-desktop.sh linux
./scripts/build-desktop.sh all             # macOS host; skips unavailable targets
```

Full desktop setup, packaging, and CI notes: **[docs/BUILD.md](docs/BUILD.md)**.

## Development

Install dependencies:

```sh
flutter pub get
```

Copy the example environment file and fill in any missing values:

```sh
cp env.example .env
```

Key variables:

- `REOWN_PROJECT_ID` — required for wallet/social login.
- `GATEWAY_URL` — Erebrus gateway base URL (default `https://gateway.erebrus.io`).
- `IPFS_GATEWAY_URL` — public IPFS gateway for CID downloads (default `https://ipfs.erebrus.io`).

Run the app with `.env` dart-defines (recommended):

```sh
scripts/build.sh run
```

Or run directly with Flutter:

```sh
flutter run --dart-define-from-file=.env
```

**Android Studio / IntelliJ:** the green **Run** button calls `flutter run`
directly, so add `--dart-define-from-file=.env` to the run configuration’s
**Additional run args**. For the **Build APK** action also include a flavor,
e.g. `--dart-define-from-file=.env --flavor playstore` or `--flavor dappstore`.

The `scripts/build.sh build-apk` and `build-appbundle` commands default to the
`playstore` flavor automatically.

Verify:

```sh
flutter analyze
flutter test
```

## CI/CD

GitHub Actions:

- **CI** — `flutter analyze` and `flutter test` on every PR and `main` push
- **Release** — manual workflow: tags `v{semver}` from `pubspec.yaml`, uploads
  Android sideload APKs plus macOS `.zip`, Windows `.zip`, and Linux `.tar.gz`
  desktop bundles

Release checklist:

1. Bump `version:` in `pubspec.yaml` (e.g. `1.0.8+8`).
2. Run `python3 scripts/generate-desktop-assets.py` if brand images changed.
3. Commit and push to `main`.
4. **GitHub → Actions → Release → Run workflow**.
5. Download artifacts from **GitHub → Releases** when the run finishes.

See [docs/BUILD.md](docs/BUILD.md).

## Native QR Scanner

The app uses its own platform-channel QR scanner instead of a third-party
Flutter scanner plugin. Android uses CameraX with ZXing QR decoding. iOS uses
AVFoundation QR metadata scanning. The scanner returns the raw Drop Link or Drop
Code to Flutter, where the existing join parser validates and opens the room.

## Local Network Debugging

Browse for advertised Drop Rooms on macOS:

```sh
dns-sd -B _erebrusdrop._tcp local
```

Resolve a discovered room:

```sh
dns-sd -L "<device name>" _erebrusdrop._tcp local
```

Check the room API:

```sh
curl http://<room-ip>:8787/api/room
```

## Privacy

Erebrus Drop is local-first. Nearby Drop Rooms transfer directly over your
Wi-Fi or hotspot without sending their contents to Erebrus services. Global
Send is a separate, explicit path that uploads the file you choose to the
selected Erebrus node.

Erebrus Drop does not collect analytics, advertising identifiers, contact
lists, or location history. Global features necessarily process the active
account session, selected node or organization, and explicitly uploaded file.

Erebrus Platform, brand, and apps are products of NetSepio.
