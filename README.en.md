# ViewFile

[中文](README.md)

Everything for Android: instant full-disk file search, a complete file manager, and WizTree-style disk usage analysis.

Flutter UI + Kotlin native engine. No background services. Three privilege tiers: Rootless / Shizuku / Root.

## Features

- **Instant search** — in-memory SoA index; sub-second queries over 1.35M entries. Lazy sessions return the total instantly and stream result pages (300 rows) on demand
- **Query syntax** — size (`>10mb`, `1mb..50mb`), dates (`today`, `>2024-01-01`), multi-token AND, e.g. `log >100mb thismonth`
- **Type filters** — images / video / audio / docs / APK / archives, executed engine-side
- **Three privilege tiers** — Rootless (MANAGE_EXTERNAL_STORAGE), Shizuku (Android/data & obb), Root (/data/data with optional deep indexing)
- **File management** — browse, copy, move, rename, share, multi-select (tap / range / invert), MD5/SHA1/SHA256 verification with progress
- **Built-in viewers** — images (zoom & swipe), video/audio (ExoPlayer), text (monospace + in-file search with highlights)
- **Archive browsing** — enter zip (pure Dart) and rar (bundled NDK-built unrar binary) as virtual folder levels; open/preview/extract inner files
- **Disk usage analysis** — WizTree-style tree (% of parent) + drill-down donut chart, with batch cleanup
- **Real-time** — foreground inotify watcher (NDK C; root raises the watch limit on demand and restores it on stop); incremental reconciliation in seconds
- **Per-app search** — locate an app's private data directories

## Privacy

- No INTERNET permission: never connects, never uploads
- No background residency: indexing only runs while the app is in the foreground
- Root hygiene: no persistent system modifications

## Performance (measured, OnePlus PLC110 / Android 15 / 1.35M entries)

| Metric | Value |
|---|---|
| Cold index load | 3.0–3.6 s |
| Foreground incremental sync | 0.2–2 s |
| Search `jpg` (18,494 hits) | 68–215 ms session, <0.1 ms per page |
| Search single letter (170k hits) | 43–116 ms |
| Memory baseline | ~380 MB PSS |
| Index database | 118 MB (87 B/entry) |

## Build

```bash
flutter pub get
flutter build apk --release
```

Requires Flutter 3.x and the Android SDK. NDK targets (vfwatch watcher, vfunrar extractor) are built automatically.

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the full architecture and field notes.

## License

MIT — the vendored unrar source (`android/app/src/main/cpp/unrar_src/`) is governed by its own license.
