# TimeFlow Studio feature checklist

Legend: **● completed** · **◐ partially completed** · **○ not implemented**

This checklist tracks TimeFlow Studio requirements and independently implemented
workflows. A filled circle means the behavior is implemented and covered by
automated tests; it does not claim compatibility with another product's
internal algorithms.

## Sequence and project management

- ● Import an entire image folder
- ● Select and import individual images
- ● Natural filename ordering and EXIF metadata loading
- ● Responsive folder import without whole-form focus/layout deadlock
- ● Save, open, autosave and crash recovery
- ● Undo and redo keyframe changes
- ● Detect and relink moved or missing source files (automatic safe match and manual folder selection)
- ○ Post-import filtering by date, filename, rating and metadata
- ○ Split one folder into multiple sequences using capture intervals
- ○ Named editing snapshots
- ○ Multi-sequence batch queue

## Metadata and Lightroom workflow

- ● Read existing XMP adjustment values
- ● Merge XMP without removing unrelated Lightroom fields
- ● Back up XMP files before replacement
- ● Export interpolated exposure and deflicker values to XMP
- ◐ Lightroom round trip: compatible sidecars exist; launch, handoff and returned-edit detection remain
- ○ Full-sequence metadata copy and paste
- ○ XMP corruption diagnosis and repair workflow
- ○ Lightroom AI-mask compatibility validation

## Keyframes and transitions

- ● Set, update, remove, copy and paste keyframes
- ● Drag exposure keyframes on a visual curve
- ● Smooth interpolation between keyframes
- ● Batch exposure offset across keyframes
- ○ Evenly spaced and automatic keyframe wizard
- ○ Straight, custom and automatic transition editor
- ○ Multi-parameter curve editor beyond exposure
- ○ Transition preservation for static values

## Luminance and deflicker

- ● Robust linear-light luminance analysis
- ● Trim isolated bright and dark outliers
- ● Deflicker correction curve with strength and smoothing window
- ● Selected-frame luminance and correction indicators
- ● Four-worker bounded analysis, cancellation and partial-result recovery
- ○ User-selectable luminance analysis region
- ○ Motion-object mask for luminance analysis
- ○ Visual deflicker using rendered previews
- ○ Multipass deflicker and refinement
- ○ Luma/chroma deflicker controls

## Day-to-night workflow

- ○ Detect ISO, shutter-speed and aperture ramps
- ○ Normalize exposure-value jumps caused by camera setting changes
- ○ Holy Grail preparation and matching wizard
- ○ White-balance transition handling
- ○ External exposure-correction import

## Preview and image pipeline

- ● Memory-bounded preview rendering
- ● Persistent 512 MB thumbnail cache with source-change invalidation
- ● sRGB/Rec.709 and Display P3 output conversion
- ○ Dedicated camera-preview and visual-preview generation workflows
- ○ Linear RAW development with camera profiles
- ○ 16-bit processing path
- ○ Crop and aspect-ratio editor
- ○ Masks and graduated/radial transition tools
- ○ Frame alignment and stabilization
- ○ General motion-blur frame blending
- ○ Digital pan and zoom

## Video export

- ● Resolution presets and editable frame rate
- ● Custom, source size, HD, Full HD, 4K UHD and vertical Full HD presets
- ● Selected start/end frame range
- ● H.264 and HEVC with target bitrate
- ● Apple ProRes 422 LT and ProRes 422
- ● Rec. 709 and Display P3 output
- ● Safe cancellation, temporary-file cleanup, and atomic replacement of an existing export
- ○ Saved user render presets
- ○ Audio track and fade controls
- ○ Sharpening and denoise controls
- ○ Timestamp overlay
- ○ Batch rendering across sequences

## Star trails

- ● Lighten-stack selected frames into TIFF
- ● Gap filling
- ● Isolated airplane/satellite streak rejection
- ● Persistent per-frame meteor marking; marked meteors bypass transient-streak rejection
- ● Configurable meteor-frame hold in ordinary timelapse, star-trail growth and mixed videos
- ● Comet-tail mode
- ● Star-trail growth video with the same six resolution presets and H.264/HEVC/ProRes choices as timelapse export
- ● Mixed-export output summary and post-export Finder reveal link
- ● Unified automatic bitrate by default for H.264/HEVC, with manual override
- ● Matching Rec. 709 and Display P3 color-space controls for timelapse and star-trail growth video
- ● Fill/crop video scaling by default to remove black bars, with optional Fit mode
- ● Continuous timelapse-to-star-trail hybrid export with transition blending and final-frame hold
- ● Project and cross-session persistence for star-trail, growth-video and hybrid-export settings
- ● Keyframe/XMP/deflicker processing shared by star-trail still and growth-video export
- ● Growth-video stacking at output resolution with bounded working memory
- ○ Frame alignment before stacking
- ○ Foreground mask and blend controls

## Release and usability

- ● Native macOS application bundle and ad-hoc local signing
- ● Tooltips on toolbar actions
- ○ Final original application icon
- ○ English/Chinese localization
- ○ Developer ID signing and Apple notarization
- ○ Automatic update mechanism
