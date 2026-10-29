# Changelog

All notable changes to TimeFlow Studio are documented here.

## 0.1.0-beta.1 — 2026-10-29

Initial public Beta candidate.

### Included

- Folder and selected-file image-sequence import.
- Robust luminance analysis and trend-preserving deflicker.
- Keyframe editing, XMP read/merge/export, autosave, and recovery.
- Timelapse export in H.264, HEVC, ProRes 422 LT, and ProRes 422.
- Static star trails, growth videos, and mixed timelapse-to-star-trail export.
- Meteor marking and hold controls.
- Safe cancellation, bounded preview/stacking memory, and atomic export replacement.

### Known limitations

- The first downloadable Beta is Apple Silicon-only, ad-hoc signed, and not
  Apple-notarized.
- RAW processing uses macOS decoding and does not yet provide camera profiles or
  a complete 16-bit linear pipeline.
- User interface localization and a final original app icon are pending.
- Beta software: preserve backups of source images and XMP sidecars.
