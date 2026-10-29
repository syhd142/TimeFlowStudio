# TimeFlow Studio

[简体中文](README.zh-CN.md) · English

TimeFlow Studio is a native macOS workflow for turning image sequences into
timelapse, star-trail growth, and mixed timelapse-to-star-trail videos. It is an
independent implementation built with SwiftUI, Core Image, ImageIO, and
AVFoundation.

> **Beta software:** keep backups of source images and XMP sidecars. Test an
> export before relying on it for important work.

## Highlights

- Import a folder or a hand-picked set of RAW/JPEG/PNG/TIFF/HEIC images.
- Analyze luminance and apply trend-preserving deflicker corrections.
- Interpolate exposure, temperature, tint, contrast, and saturation keyframes.
- Read, merge, and back up Adobe Camera Raw-compatible XMP sidecars.
- Export H.264, HEVC, ProRes 422 LT, or ProRes 422 video in common presets.
- Create still star trails, star-trail growth movies, and mixed transitions.
- Mark meteor frames, preserve them during streak filtering, and add a hold.
- Cancel long operations safely; completed exports replace older files only
  after the new output has finished successfully.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon for the initial unsigned Beta build

## Download

Download the newest build from [GitHub Releases](../../releases). The initial
Beta is ad-hoc signed and not yet notarized. macOS may require Control-clicking
the app and choosing **Open** the first time. Verify the downloaded file against
the published SHA-256 checksum.

## Build from source

Install Xcode Command Line Tools, then run:

```bash
swift build
swift test
swift run TimeFlow
```

Create a local application bundle with:

```bash
./scripts/package_app.sh
```

The project has no third-party package dependencies. It links only Apple system
frameworks.

## Project status

See [FEATURE_CHECKLIST.md](FEATURE_CHECKLIST.md) for current coverage and
[ROADMAP.md](ROADMAP.md) for planned work. Bugs and feature requests are welcome
through GitHub Issues.

## Independence and compatibility

TimeFlow Studio is developed from independent requirements and documented file
formats. Contributions must follow the [clean-room policy](docs/CLEAN_ROOM_POLICY.md)
and must not include proprietary code, artwork, text catalogs, credentials, or
license-bypass material from another product.

## License

Source code is available under the [Mozilla Public License 2.0](LICENSE).
MPL-2.0 applies at the file level. The license does not grant rights to the
TimeFlow Studio name or project branding; see [TRADEMARKS.md](TRADEMARKS.md).

See also [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
[PRIVACY.md](PRIVACY.md), and [SUPPORT.md](SUPPORT.md).
