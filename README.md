# S-Video — Sleepy Time Video Player

A focused, iPad-only RSS & Atom video feed player built for falling asleep to your video feeds, with fast, reliable iCloud sync across 2+ iPads.

- **App Store Name:** `S-Video`
- **Subtitle:** `Sleepy Time Video Player`

## Features

- **Single Chronological Timeline:** Unwatched, in-progress, and recently completed videos in one reverse-chronological feed.
- **Universal Video Feeds (No Filtering):** Subscribes to any RSS 2.0 or Atom video feed (video podcasts, PeerTube, Vimeo, YouTube channels, self-hosted feeds) with no content-type filtering or ad-blocking.
- **Deterministic iCloud Sync (`CKSyncEngine`):** Syncs only lightweight feed subscriptions and watch states using deterministic CloudKit record IDs (`channel:<id>`, `state:<id>`) and timestamp-based conflict resolution—no duplicates and instant setup on additional iPads.
- **Bedtime Sleep Timer & Dim Screen:** 15 / 30 / 45 / 60 minute countdowns or End of Video with a gentle 15-second audio fade-out before pausing, plus a nightstand Dim Screen overlay (40% / 65% / 80%).
- **Adaptive Playback:** Native `AVPlayer` for direct video enclosures (`.mp4`/`.m4v`/`.mov`/`.m3u8`), direct top-level `WKWebView` player for YouTube, and inline `WKWebView` for other web video pages—with resume support and timecode tracking.
- **Copy Link & Timecode:** Copy a plain video link or a link at the current timecode (`?t=<seconds>` / `#t=<seconds>`).
- **View in Browser:** Open any video at its current timecode in an in-app Safari sheet or external Safari.
- **Backup & Import/Export:** Standard OPML and S-Video JSON (feeds + watch states).

## Building & App Store Submission

1. Signing is configured in `Config.xcconfig` (`DEVELOPMENT_TEAM = 43L352U8Y8`, `SVIDEO_BUNDLE_ID = io.bino.svideo`, `SVIDEO_ICLOUD_CONTAINER = iCloud.io.bino.svideo`).
2. Generate the Xcode project and run tests:
   ```zsh
   ./scripts/test.zsh
   ```
3. Archive (and optionally upload directly to App Store Connect by setting `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`):
   ```zsh
   ./scripts/archive.zsh
   ./scripts/archive.zsh --upload
   ```
4. Run once on a signed iPad (Development) to initialize the CloudKit schema (`SVChannel`, `SVVideoState` in `SVideoZone`), then deploy the schema from Development to Production in CloudKit Console before App Store release.

## Planned Future Features

- **Per-Device Playlists (Not Yet Enabled):** A `+` button in the left sidebar to create local Playlists with an optional custom name, a default initial state (empty or populated from the current timeline), and manual drag-handle reordering. Playlists will be device-specific—included in JSON backups, but **not** synchronized via iCloud (iCloud Sync remains strictly limited to video sources and read/watched/progress states).
