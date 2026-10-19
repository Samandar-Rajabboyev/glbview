import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'glb_parser.dart';
import 'glb_style.dart';

/// Thin wrapper over the `dev.samandar/glbview` method channel.
class GlbChannel {
  GlbChannel._();

  static const MethodChannel _channel = MethodChannel('dev.samandar/glbview');

  /// Creates a native renderer of [width]x[height] device pixels and returns
  /// its Flutter texture id. [autoRotate] is in degrees per second (0 = off).
  static Future<int> create({
    required int width,
    required int height,
    required double autoRotate,
    bool debugTimings = false,
  }) async {
    final id = await _channel.invokeMethod<int>('create', {
      'width': width,
      'height': height,
      'autoRotate': autoRotate,
      'debugTimings': debugTimings,
    });
    if (id == null) {
      throw PlatformException(code: 'create_failed', message: 'No texture id');
    }
    return id;
  }

  /// Uploads [model] into the native GPU store under [key] (replacing any
  /// previous model with that key). Completes when it is ready to draw.
  static Future<void> cacheModel(String key, GlbModel model,
      {bool debugTimings = false}) {
    return _channel.invokeMethod<void>('cacheModel', {
      'key': key,
      'debugTimings': debugTimings,
      'primitives': [
        for (final p in model.primitives)
          {
            'vertices': p.vertices,
            // The codec has no Uint32List; indices fit in int32, so send the
            // same bytes viewed as Int32List.
            'indices': Int32List.sublistView(p.indices),
            'baseColor': p.baseColor,
            'texture': p.texture,
            'metallic': p.metallic,
            'roughness': p.roughness,
            'normalTexture': p.normalTexture,
            'normalScale': p.normalScale,
            'metallicRoughnessTexture': p.metallicRoughnessTexture,
            'clearcoat': p.clearcoat,
          },
      ],
    });
  }

  /// Frees a cached model once no view draws it.
  static Future<void> evictModel(String key) =>
      _channel.invokeMethod<void>('evictModel', {'key': key});

  /// Makes view [id] draw the cached model [key].
  static Future<void> setModel(int id, String key) =>
      _channel.invokeMethod<void>('setModel', {'id': id, 'key': key});

  /// Per-view replacements for primitives of the current model; an empty
  /// list restores the model's own materials. Completes once applied.
  static Future<void> setOverrides(
      int id, List<Map<String, Object?>> overrides) {
    return _channel
        .invokeMethod<void>('setOverrides', {'id': id, 'overrides': overrides});
  }

  static Future<void> setCamera(
    int id, {
    required double yaw,
    required double pitch,
    required double distance,
  }) {
    return _channel.invokeMethod<void>('setCamera', {
      'id': id,
      'yaw': yaw,
      'pitch': pitch,
      'distance': distance,
    });
  }

  /// Updates shading without recreating the texture. Colors are ARGB ints.
  static Future<void> setStyle(int id, GlbStyle style) {
    return _channel.invokeMethod<void>('setStyle', {
      'id': id,
      ...style.toMap(),
    });
  }

  static Future<void> dispose(int id) =>
      _channel.invokeMethod<void>('dispose', {'id': id});
}
