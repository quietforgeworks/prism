# Prism 1.0.12

## Changes since 1.0.8

- Command/Shift multi-selection and ordered multi-item transfers.
- Broader image, document, and file-format compatibility, with explicit unavailable-file handling.
- Improved scrolling and reduced repeated layout and decoding work.
- Visible thumbnails load immediately; bounded nearby prefetch uses two concurrent decodes and a 20 MB thumbnail cache.

## Validation

A clean release build completed on Apple Silicon with Swift 6.4.2. The newly built executable passed 55 built-in regression checks with zero failures using private pasteboards and disposable storage. The optional external codec-fixture check was not run in this audit. The release app was ad-hoc signed and passed strict code-signature validation after removing Finder metadata from the isolated output. Existing installed apps and clipboard history were not replaced.

## Requirements and limitations

macOS 26 or later, Apple Silicon only. Ad-hoc signed, not Developer ID signed or notarized. Fresh-machine installation, upgrade, permissions, sustained scrolling, and every third-party drag destination are not comprehensively verified. Database and backups have no application-level encryption. Link previews access the selected website.

## Next steps

Expand real-app transfer testing, long-session scrolling measurements, and installation/permission coverage.
