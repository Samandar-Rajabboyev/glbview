import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'glb_parser.dart';

/// Replaces inputs of one glTF material at runtime, e.g. a per-tier texture
/// drawn with `dart:ui` and encoded to PNG. Unset fields keep the file's
/// values.
///
/// Equality compares the byte buffers by identity, so keep the same
/// [Uint8List] instances across rebuilds (cache generated textures); a new
/// buffer re-uploads the model.
@immutable
class GlbMaterialOverride {
  const GlbMaterialOverride({
    this.baseColorTexture,
    this.normalTexture,
    this.metallicRoughnessTexture,
    this.baseColor,
  });

  /// Encoded PNG/JPEG, sRGB.
  final Uint8List? baseColorTexture;

  /// Encoded tangent-space normal map (glTF convention: green up).
  final Uint8List? normalTexture;

  /// Encoded metallic-roughness map (G = roughness, B = metallic).
  final Uint8List? metallicRoughnessTexture;

  /// Replaces `baseColorFactor`, which multiplies the texture. Given in sRGB
  /// like any Flutter color; converted to glTF's linear factor.
  final Color? baseColor;

  @override
  bool operator ==(Object other) =>
      other is GlbMaterialOverride &&
      identical(other.baseColorTexture, baseColorTexture) &&
      identical(other.normalTexture, normalTexture) &&
      identical(other.metallicRoughnessTexture, metallicRoughnessTexture) &&
      other.baseColor == baseColor;

  @override
  int get hashCode => Object.hash(
      identityHashCode(baseColorTexture),
      identityHashCode(normalTexture),
      identityHashCode(metallicRoughnessTexture),
      baseColor);
}

extension GlbModelOverrides on GlbModel {
  /// A copy of this model with [overrides] applied, keyed by material name
  /// (see [GlbPrimitive.materialName]). Geometry is shared.
  GlbModel withMaterialOverrides(Map<String, GlbMaterialOverride>? overrides) {
    if (overrides == null || overrides.isEmpty) return this;
    assert(() {
      final names = {for (final p in primitives) p.materialName};
      final unknown = overrides.keys.where((k) => !names.contains(k));
      if (unknown.isNotEmpty) {
        debugPrint('GlbView: no material named ${unknown.join(', ')}; '
            'this model has ${names.whereType<String>().join(', ')}');
      }
      return true;
    }());
    return GlbModel([
      for (final p in primitives)
        if (overrides[p.materialName] case final o?)
          p.copyWith(
            baseColor: o.baseColor == null ? null : linearFactor(o.baseColor!),
            texture: o.baseColorTexture,
            normalTexture: o.normalTexture,
            metallicRoughnessTexture: o.metallicRoughnessTexture,
          )
        else
          p,
    ]);
  }
}

/// An sRGB Flutter color as a linear glTF color factor.
Float32List linearFactor(Color c) {
  double lin(double v) => math.pow(v, 2.2).toDouble();
  return Float32List.fromList([lin(c.r), lin(c.g), lin(c.b), c.a]);
}
