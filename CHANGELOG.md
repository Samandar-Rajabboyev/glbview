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
