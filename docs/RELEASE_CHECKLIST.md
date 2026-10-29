# Release checklist

## Code and tests

- [ ] Update version and changelog.
- [ ] Run `swift test` with no failures.
- [ ] Import and analyze a large real-world sequence.
- [ ] Verify ordinary, star-trail growth, and mixed export.
- [ ] Verify cancellation preserves an existing destination.
- [ ] Scan tracked files for secrets, personal paths, and private media.

## Package

- [ ] Run `./scripts/package_release.sh VERSION`.
- [ ] Mount the DMG and launch the copied app.
- [ ] Verify the architecture and code signature.
- [ ] Compare the DMG with its SHA-256 checksum.
- [ ] With Developer ID: sign, notarize, staple, then verify with Gatekeeper.

## GitHub

- [ ] Create and push an annotated version tag.
- [ ] Draft a GitHub Release from the bilingual template.
- [ ] Upload DMG and `.sha256` assets.
- [ ] Confirm the automatically attached source archives match the tag.
- [ ] Publish only after the download and first-launch instructions are tested.
