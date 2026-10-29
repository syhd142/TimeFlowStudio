# Contributing

Thank you for helping improve TimeFlow Studio.

## Before opening a change

1. Search existing issues and open a focused issue for significant behavior or
   UI changes.
2. Keep changes small enough to review and include tests for bug fixes and new
   processing behavior.
3. Follow the [independent implementation policy](docs/CLEAN_ROOM_POLICY.md).
4. Do not include photos, XMP files, paths, or metadata that you do not have
   permission to publish.

## Local checks

```bash
swift test
./scripts/package_app.sh
```

For export changes, test cancellation, replacement of an existing destination,
the selected frame range, and at least one H.264 or ProRes output.

## Contribution license

By submitting a contribution, you agree that it is your original work (or that
you have sufficient rights to submit it) and that it is licensed under
MPL-2.0, the license of this repository. No contributor license agreement is
required.
