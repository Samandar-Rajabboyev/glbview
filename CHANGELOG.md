## 0.3.3

* Fix: rotate/tilt snapped back at the start of a new drag on iOS when
  using `GlbGesture.orbit` or a single drag gesture (since 0.3.1). The
  first move event of a new touch can carry a delta measured from the
  previous touch, and drag recognizers sum event deltas. Rotation and
  tilt now come from each finger's own successive positions; recognizers
  only decide when a drag is active.

## 0.3.2

* Fix: a second finger on the view (e.g. an attempted pinch) made rotate
  and tilt jump, most visibly on iOS where drag deltas average all fingers.
  Rotate/tilt now follow a single finger only; with `GlbGesture.zoom` two
  fingers zoom as before.

## 0.3.1

* `gestures`: any combination of `GlbGesture.rotate`, `GlbGesture.tilt` and
  `GlbGesture.zoom` (presets `all`, `orbit`, `none`). The view picks the
  narrowest recognizer, so e.g. a rotate-only view inside a vertical
  `ListView` lets the list scroll.
* `interactive` is deprecated; `interactive: false` equals
  `gestures: GlbGesture.none`.

## 0.3.0

* Precaching: `GlbView.precacheAsset` / `GlbView.precacheMemory` parse and
  upload a model ahead of time; showing it later takes about one frame.
  `evictAsset`, `evictMemory`, `clearCache` and `maxUnusedModels` manage the
  cache. `GlbView.memory` gains `cacheKey`.
* Models are now cached across views and screen visits: parsed once,
  uploaded to the GPU once, shared by every `GlbView`.
* Faster cold loads: indexed geometry (about 4x less parse work and data for
  typical models), parallel texture decoding, and the shader compiles in the
  background when the plugin starts.
* Android: one GL thread and context for all views instead of one per view.
* iOS: one shared Metal pipeline and model store.
* Material overrides are applied per view on the GPU, without re-uploading
  geometry.
* `GlbView.debugTimings` logs load timings.
* Breaking: `GlbPrimitive` now has `indices`; `vertices` holds unique
  vertices instead of one vertex per triangle corner.

## 0.2.0

* `materialOverrides` on `GlbView`: replace a material's base color texture,
  normal map, metallic-roughness map or base color at runtime, keyed by
  material name. Changes re-upload the cached model without re-parsing or
  recreating the texture.
* `GlbPrimitive.materialName` and `GlbPrimitive.copyWith`.
* Example: cube faces drawn at runtime with `dart:ui`.

## 0.1.1

* No functional changes; republished after 0.1.0.

## 0.1.0

* Initial release.
* GLB (binary glTF 2.0) parser in Dart: node hierarchy, all accessor types,
  base color, metallic-roughness, normal maps (with generated tangents) and
  clearcoat.
* Native renderers: OpenGL ES 2.0 on Android, Metal on iOS, shown through a
  Flutter `Texture`, with 4x MSAA.
* Glossy PBR shading with a procedural studio environment and sparkle;
  style changes apply live without recreating the texture.
