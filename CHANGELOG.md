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
