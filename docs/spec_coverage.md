# Erebrus Drop Spec Coverage

Current app version: `1.0.10+10`

## Implemented in this repo

- Flutter Android/iOS app scaffold in the repository root.
- Package/bundle identity: `com.erebrus.drop`.
- Dark Material 3 theme in `lib/ui/theme/drop_theme.dart`.
- Home, Rooms, Library, Smart Send, and Grab tabs; Settings opens from the Home gear (desktop: side rail).
- Grab: on-device media downloader for public links (YouTube, X, TikTok, Reddit, Bluesky, Vimeo, SoundCloud, direct/HLS) with bundled FFmpeg for merging, MP3 encoding and muting.
- Start Drop Room flow on current network.
- Password-protected room auth with PBKDF2-HMAC-SHA256.
- Local HTTP server on port `8787` with fallback ports through `8799`.
- Browser Drop Link and QR code.
- Bundled browser SPA in `assets/web/drop_client/`.
- Browser login, polished file manager UI, breadcrumbs, icon controls, folder shortcuts, storage visualization, drag/drop upload, file list, folder creation, raw and multipart upload, download, ZIP bundle download, text paste, and media stream links.
- Browser multi-select for files, bundled file downloads, folder ZIP downloads, and upload progress with percent, speed, and ETA.
- WebDAV endpoint at `/dav` for compatible file managers and desktop clients, with folder listing, upload, download, folder creation, delete, move, and lock compatibility.
- HTTP range request support for streamed file responses.
- Storage snapshot via platform channel when available, with short cache/single-flight protection to avoid repeated scans during transfers.
- Room storage requires an OS-visible Drop folder selected from phone storage or Files; app-private hosting fallback is disabled.
- Start Room blocks hosting until the host selects or creates an `ErebrusDrop` folder in the OS folder picker.
- Library shows the active Drop folder source, browses the active root, opens folders, and can hand files to the system viewer/previewer.
- First-run onboarding with the required three slides.
- Manual native Join flow can preview `/api/room`, authenticate to `/api/auth/login`, list remote files, create folders, send text, and download files.
- Android and iOS app clients can multi-pick and upload files to the selected/default joined-room folder, with progress, speed, and ETA.
- Native joined-room downloads show progress, speed, and ETA.
- Native QR scanner reads raw Drop Links and spec JSON Drop Code payloads, then opens Manual Join.
- Android QR scanning uses CameraX with ZXing decoding, avoiding ML Kit and third-party Flutter scanner runtime issues.
- Android QR scanning handles Android 15 edge-to-edge system insets without deprecated system bar color APIs.
- iOS QR scanning uses AVFoundation QR metadata detection.
- Android and iOS share-sheet text and file intake can populate Smart Send or import files into a live room.
- Live Drop Rooms survive share-intent-triggered Flutter UI recreation and stop only through explicit host stop/quit actions.
- Android local-only hotspot can be requested through the platform channel; unsupported/OEM-denied devices show a manual guide.
- Android foreground hosting service keeps a room higher priority while it is live.
- App lifecycle-aware refresh avoids background UI polling while a room is being served.
- Room creators can choose and persist an OS-visible Drop folder source.
- Default permission mode is `Drop folder only`, scoping guests to the creator-selected drop folder.
- Android host-folder picker can request and persist a user-granted Storage Access Framework tree URI from Settings.
- Android hosted rooms can list, create folders, save text, upload, download, stream, and open files from the selected Storage Access Framework folder.
- iOS can host from user-selected Files/iCloud folders through saved folder bookmarks.
- iOS hosted rooms can list, create folders, save text, upload, download, stream, and preview/open files from the selected Files folder.
- Android/iOS platform-channel methods for local IP and storage stats.
- Local IP selection prefers active Wi-Fi/LAN addresses and de-prioritizes carrier/VPN/CGNAT-looking addresses.
- Android and iOS publish active rooms through mDNS/DNS-SD as `_erebrusdrop._tcp`.
- Android and iOS discover nearby rooms through mDNS/DNS-SD on the local network.
- Server-to-server transfer APIs can pull files from a joined room into the current live room and push local room files to another room.

## Files added for next spec phases

- `lib/features/host/host_folder_service.dart`
- `lib/features/join/join_room_service.dart`
- `lib/features/nearby/nearby_room_service.dart`
- `lib/features/host/hotspot_service.dart`
- `lib/features/host/room_runtime_service.dart`
- `lib/features/smart_send/ocr_service.dart`
- `lib/features/smart_send/share_intake_service.dart`
- `lib/features/library/library_repository.dart`
- `lib/features/settings/drop_settings.dart`
- `lib/features/media/media_streaming.dart`
- `lib/server/discovery/discovery_contract.dart`
- `lib/server/streaming/range_request.dart`
- `lib/features/media_grab/` (Grab: extractors, HLS selection, FFmpeg pipeline, panel UI)

## Still needs plugin/native/device implementation

- Grab: Instagram/Facebook (need login), playlists, and a live TikTok check outside regions where TikTok is blocked.
- Remaining external host-folder storage adapter work:
  - Android SAF delete/rename implementation for hosted rooms.
  - iOS Files/iCloud delete/rename implementation for hosted rooms.
- Offline OCR through Android ML Kit and iOS Vision.
- Persistent metadata database.
- Full server-to-server folder mirroring and conflict controls.
