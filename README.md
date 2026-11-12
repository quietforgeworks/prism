# Prism

Prism is a macOS menu bar clipboard manager with searchable history, favorites, image OCR, and quick paste workflows.

## Features

- Search clipboard history and organize items with categories and favorites.
- Extract text from images.
- Use keyboard shortcuts, a paste queue, and quick paste.
- Keep history locally and import or export backups.

## Requirements and download

Requires **macOS 26 or later on Apple Silicon (arm64)**.

Download `Prism-1.0.8-macOS-arm64.zip` from [Releases](https://github.com/quietforgeworks/prism/releases), extract it, and move `Prism.app` to Applications. Releases also include a complete source ZIP and SHA-256 checksums.

## Current limitations

- The clipboard database and exported backups have no application-level encryption.
- Link previews use WebKit to load the selected URL over the network.
- Automatic paste requires the relevant macOS permissions; copying an item and pasting manually is available without automatic paste.
- Distribution uses ad-hoc signing rather than Developer ID signing and Apple notarization, so macOS may block the first launch.
- Independent clean-install, upgrade, and permission regression testing remains incomplete.

## Development directions

- Refine search, OCR, and paste workflows.
- Improve history, backup, and data-management controls.
- Expand installation, upgrade, and permission test coverage.

## Build and documentation

Source and build scripts are in `Source/`. Run `bash Build.command` in that directory on a supported Mac. See the [usage and build guide](Source/README.md) for toolchain requirements and the [privacy reference](Source/PRIVACY.md) for collection, retention, cleanup, and network behavior.

## License

[MIT](LICENSE). Dependency and attribution information is in [THIRD-PARTY.md](Source/THIRD-PARTY.md).
