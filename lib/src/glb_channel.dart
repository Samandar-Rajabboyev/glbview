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
  }) async {
    final id = await _channel.invokeMethod<int>('create', {
      'width': width,
      'height': height,
      'autoRotate': autoRotate,
    });
    if (id == null) {
      throw PlatformException(code: 'create_failed', message: 'No texture id');
    }
    return id;
  }

  static Future<void> loadModel(int id, GlbModel model) {
    return _channel.invokeMethod<void>('loadModel', {
      'id': id,
      'primitives': [
        for (final p in model.primitives)
          {
            'vertices': p.vertices,
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
