# Prism 1.0.8

Prism is a macOS menu bar clipboard manager with searchable history, categories, favorites, image OCR, backup import and export, and quick paste.

## Requirements and installation

- macOS 26 or later on Apple Silicon (arm64).
- The downloadable app uses an ad-hoc signature and is not Apple-notarized. macOS may require approval on first launch.
- Extract the release ZIP and move `Prism.app` to Applications.

Open history from the menu bar or with the default shortcut ⇧⌘V. The copy queue uses ⇧⌘C. Shortcuts can be changed in settings.

Prism starts recording newly copied content when launched. Automatic paste requires the relevant macOS event-sending or Accessibility permission. Without it, copy an entry and paste manually with ⌘V.

## Storage and retention

- Default limits are 30 days, 1,000 history entries, and 512 MB. Settings provide retention controls, pause, application exclusions, and history cleanup.
- Clipboard text, images, file references, source-app details, and local search/OCR data are stored under `~/Library/Application Support/Prism/`.
- Storage uses local SQLite and files, with permissions such as 0700 for directories and 0600 for files. The database and exported `.prismbackup` files have no application-level encryption.
- Common password-manager exclusions, secure-input pause, and sensitive clipboard-type filtering are included. Ordinary copied text can still contain sensitive data; recording can be paused.
- Clear History preserves favorites. Image drag files use a separate temporary cache with a default 24-hour retention period. Cleanup is not immediate secure erasure. Migration archives and exported backups are separate from history cleanup.

## Link previews and network access

Link previews load the selected URL and its page resources through WebKit, using nonpersistent website storage. These requests expose the normal URL, IP address, and browser-request information to the destination. Open Link uses the default browser.

There is no implementation for automatically uploading clipboard history or telemetry to a developer server. See [PRIVACY.md](PRIVACY.md) for the full data behavior.

## Updating and removing the app

Quit the old version before replacing it. The new version reuses the app's local data. Backup export is available before upgrading.

Removing `Prism.app` leaves history, favorites, preferences, drag caches, and exported backups in place. Application cleanup does not remove copies in system backups.

## Build and test

Use Xcode or command-line tools with the macOS 26 SDK and a Swift 6 toolchain. From this directory, run:

```sh
./Build.command
```

The script builds a release app and applies an ad-hoc signature. Dependencies are Apple system frameworks and system SQLite, with no external Swift packages.

Run the generated app's self-test on a Mac:

```sh
../Prism.app/Contents/MacOS/Prism --self-test
```

## Current limitations and next steps

Intel Macs and older macOS versions are not supported. Independent fresh-install, upgrade, permission, build, and self-test validation remain incomplete. The next development step is broader installation and permission testing across supported Macs.

## License and sources

Released under the [MIT license](LICENSE). Apple trademarks, system frameworks, and third-party content retain their respective rights. See [THIRD-PARTY.md](THIRD-PARTY.md) for dependencies and sources.
