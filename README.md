# glbview

Native GLB (binary glTF 2.0) viewer for Flutter. The model is parsed once in
Dart (in a background isolate) into flat, world-space triangles, then rendered
natively and shown through a `Texture` widget:

- **Android**: OpenGL ES 2.0 on a dedicated EGL thread, drawing into a
  `SurfaceTexture` from Flutter's `TextureRegistry`.
- **iOS**: Metal, drawing into IOSurface-backed `CVPixelBuffer`s exposed as a
  `FlutterTexture`.

No WebView or third-party 3D packages.

<p>
  <img src="https://raw.githubusercontent.com/Samandar-Rajabboyev/glbview/main/doc/screenshots/cube.png" width="260" alt="Glossy textured cube">
  <img src="https://raw.githubusercontent.com/Samandar-Rajabboyev/glbview/main/doc/screenshots/star.png" width="260" alt="Metallic gold star">
</p>
<img src="https://raw.githubusercontent.com/Samandar-Rajabboyev/glbview/main/doc/screenshots/matte_vs_glossy.png" width="526" alt="Matte vs glossy comparison">

```dart
GlbView.asset(
  'assets/model.glb',
  width: 300,
  height: 300,
  autoRotate: true,
  autoRotateDegreesPerSecond: 20,
  gestures: GlbGesture.all,   // any set of rotate / tilt / zoom
  initialYaw: 0,
  initialPitch: 10,
  initialDistance: 3.2,
  placeholder: const CircularProgressIndicator(),
  errorBuilder: (context, error) => Text('$error'),
)

GlbView.memory(bytes, width: 300, height: 300)
```

### Glossy look

Shading defaults to a glossy "glass/candy" look: normalized Blinn-Phong,
Fresnel, a procedural studio environment, a clearcoat lobe and animated
procedural sparkle (no image assets), with 4x MSAA on both platforms. Style
props update the native renderer live without recreating the texture:

```dart
GlbView.asset(
  'assets/model.glb',
  glossy: true,                 // false = plain matte lighting
  gloss: 1.0,                   // 0..1
  glossOverridesMaterial: true, // false = use the file's roughnessFactor
  gradientColors: const [Color(0xFF7B5CFF), Color(0xFFFF6FD8)], // env top, bottom
  gradientMix: 0.0,             // screen-space tint of the base color
  sparkle: 0.5,
  specularColor: Colors.white,
)
```

### Gestures

`gestures` takes any combination of `GlbGesture.rotate` (horizontal drag,
yaw), `GlbGesture.tilt` (vertical drag, pitch) and `GlbGesture.zoom` (pinch).
Presets: `GlbGesture.all` (default), `GlbGesture.orbit` (rotate + tilt) and
`GlbGesture.none`.

The view uses the narrowest gesture recognizer for the set, so drags it
doesn't handle reach ancestors: with `{GlbGesture.rotate}` a vertical
`ListView` still scrolls when the drag starts on the model. Zoom needs a
scale recognizer, which also takes vertical drags.

```dart
GlbView.asset('assets/badge.glb', gestures: {GlbGesture.rotate});
```

### Instant loading (precache)

Models are parsed once and uploaded to the GPU once, then shared by every
`GlbView` and kept for later visits. Precache before navigating and the
screen shows the model on its first frame or two:

```dart
@override
void initState() {
  super.initState();
  GlbView.precacheAsset('assets/badge.glb'); // or precacheMemory(bytes)
}
```

- `GlbView.maxUnusedModels` (default 4) bounds how many models no view is
  showing stay on the GPU, least recently used evicted first.
- `GlbView.evictAsset`, `GlbView.evictMemory` and `GlbView.clearCache` free
  them explicitly.
- `GlbView.debugTimings = true` logs each phase (read, parse, GPU upload,
  first frame).

Without precaching, the first open of a ~2 MB model (60k triangles, six
1024² textures) takes about 300 ms on a mid-range Android phone; precached
or repeat opens take about one frame. The shader compiles in the
background when the plugin starts, so the first view doesn't pay for it.

### Material overrides

Swap a material's textures or color at runtime, keyed by the glTF material
name, e.g. per-tier badge faces drawn with `dart:ui` and encoded to PNG.
Changing overrides re-uploads the already-parsed model to the same native
texture: no re-parse, no texture recreation.

```dart
GlbView.asset(
  'assets/badge.glb',
  materialOverrides: {
    'back': GlbMaterialOverride(
      baseColorTexture: tierPng,      // cache it: compared by identity
      baseColor: Colors.white,        // optional, sRGB
    ),
  },
)
```

Primitives that share a material are merged, so one override covers every
mesh using that material. `GlbPrimitive.materialName` lists the names.

## Supported glTF

- Node hierarchy of the default scene (matrix or TRS), flattened to world space
- Triangles (plus strips and fans, converted); points and lines are skipped
- All accessor component types, `normalized`, `byteStride`, accessors without
  a bufferView, uint8/16/32 indices
- `POSITION`, `NORMAL` (flat normals generated when missing), `TEXCOORD_0`
- `baseColorFactor` and `baseColorTexture` (PNG/JPEG embedded in the GLB)
- Metallic-roughness workflow: `metallicFactor`/`roughnessFactor`,
  `metallicRoughnessTexture`, `normalTexture` (tangents read from `TANGENT`
  or generated), and `KHR_materials_clearcoat` factor
- Models are centered and scaled to a unit bounding sphere

Not supported (clear `GlbFormatException`): Draco/meshopt compression, sparse
accessors, external `.bin` files. Skins, animations, morph targets,
occlusion and emissive maps are ignored. Shading is GGX with a procedural
studio environment; both platforms' shaders are generated from one source by
`tool/gen_shaders.py`.

## Example

`example/` shows two generated sample models (`example/tool/make_test_glb.py`),
a broken file to demonstrate the error UI, and a matte-vs-glossy screen with
live style controls. Drop your own models into `example/assets/local/`
(git-ignored); the "Badge" option loads `yia_top1_badge.glb` from there.
