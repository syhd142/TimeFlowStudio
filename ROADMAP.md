# TimeFlow Studio roadmap

## Completed in the current build

- Safe XMP import and merge. Existing Lightroom/Camera Raw fields are preserved, and replaced sidecars are backed up in `.timeflow-xmp-backups`.
- Interactive exposure-keyframe curve with direct dragging, copy/paste, and batch EV offsets.
- Robust luminance analysis using linear-light sampling and trimmed highlights/shadows.
- Undo/redo for keyframe edits, autosave, and crash recovery.
- Large-sequence foundations: bounded four-worker luminance analysis, cancellation with partial-result retention, incremental recovery checkpoints, and a size-bounded persistent thumbnail cache.
- Video export presets: H.264, HEVC, ProRes 422 LT/422, target bitrate, Rec. 709/Display P3, resolution presets, frame range, and safe cancellation.
- Select individual source images, memory-bounded previews, deflicker, video export, and star-trail image/growth-video export.
- Missing-source detection with safe automatic and user-selected folder relinking; ambiguous duplicate filenames are never guessed.
- Star-trail production hardening: output-resolution growth stacking, bounded working memory, cancellation, temporary-file cleanup, and atomic destination replacement.
- Pipeline consistency: keyframes, source XMP adjustments, and deflicker corrections are applied to star-trail still, growth, and mixed-video exports.
- Accurate luminance-analysis completion counts and progress status.

## P1 — next production work

- RAW color management: camera profiles, linear RAW data, and a 16-bit render path.
- Star-trail image quality: 16-bit stacking, true working/output color management, frame alignment, foreground masks, and region-specific meteor preservation.
- Large-sequence follow-up: resumable analysis across launches and user-configurable cache limits.
- Advanced day-to-night transitions driven by ISO, shutter speed, and aperture metadata.
- Selectable luminance-analysis regions and moving-object masks.
- Video follow-up: audio tracks, sharpening, denoise, timestamps, batch rendering, and saved user presets.

## P2 — advanced workflow and release work

- Frame alignment, crop, digital pan/zoom, and motion-blur frame blending.
- Reusable adjustment/deflicker presets and multi-sequence batch processing.
- Final icon, localization, update system, Developer ID signing, and Apple notarization.

Developer ID signing and notarization require the owner's Apple Developer certificate and account authorization; the local development build currently uses ad-hoc signing.
