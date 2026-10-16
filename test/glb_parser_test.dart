import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glbview/glbview.dart';

Uint8List _asset(String name) => File('example/assets/$name').readAsBytesSync();

double _maxRadius(GlbModel model) {
  var r = 0.0;
  for (final p in model.primitives) {
    final v = p.vertices;
    for (var i = 0; i < v.length; i += kFloatsPerVertex) {
      r = math.max(r,
          math.sqrt(v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2]));
    }
  }
  return r;
}

void main() {
  test('parses the textured cube', () {
    final model = parseGlb(_asset('cube.glb'));
    expect(model.primitives, hasLength(1));
    final p = model.primitives.single;
    expect(p.vertexCount, 36);
    expect(p.texture, isNotNull);
    expect(p.texture!.sublist(1, 4), 'PNG'.codeUnits);
    expect(p.baseColor, [1, 1, 1, 1]);
    expect(p.metallic, 0); // metallicFactor: 0 in the file
    expect(p.roughness, 1); // glTF default
    expect(_maxRadius(model), closeTo(1, 1e-5));

    // Tangents are unit, perpendicular to the normal, and follow +u; the
    // bitangent cross(N, T) * w points along -v (glTF normal-map convention).
    for (var i = 0; i < p.vertices.length; i += kFloatsPerVertex) {
      final v = p.vertices;
      final n = [v[i + 3], v[i + 4], v[i + 5]];
      final t = [v[i + 8], v[i + 9], v[i + 10]];
      expect(t[0] * t[0] + t[1] * t[1] + t[2] * t[2], closeTo(1, 1e-5));
      expect(n[0] * t[0] + n[1] * t[1] + n[2] * t[2], closeTo(0, 1e-5));
      expect(v[i + 11].abs(), 1);
    }

    // Normals stay unit length and face away from the center.
    final v = p.vertices;
    for (var i = 0; i < v.length; i += kFloatsPerVertex) {
      final nLen = math.sqrt(
          v[i + 3] * v[i + 3] + v[i + 4] * v[i + 4] + v[i + 5] * v[i + 5]);
      expect(nLen, closeTo(1, 1e-5));
      final dot = v[i] * v[i + 3] + v[i + 1] * v[i + 4] + v[i + 2] * v[i + 5];
      expect(dot, greaterThan(0));
    }
  });

  test('parses the star with generated normals and node transforms', () {
    final model = parseGlb(_asset('star.glb'));
    final p = model.primitives.single;
    expect(p.vertexCount, 10 * 4 * 3);
    expect(p.texture, isNull);
    expect(p.baseColor[1], closeTo(0.62, 1e-6));
    expect(_maxRadius(model), closeTo(1, 1e-5));

    // Flat normals face the same way as the triangle's winding (CCW).
    final v = p.vertices;
    for (var t = 0; t < p.vertexCount; t += 3) {
      final o = t * kFloatsPerVertex;
      final a = [v[o], v[o + 1], v[o + 2]];
      final b = [
        v[o + kFloatsPerVertex],
        v[o + kFloatsPerVertex + 1],
        v[o + kFloatsPerVertex + 2]
      ];
      final c = [
        v[o + 2 * kFloatsPerVertex],
        v[o + 2 * kFloatsPerVertex + 1],
        v[o + 2 * kFloatsPerVertex + 2]
      ];
      final e1 = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
      final e2 = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
      final cross = [
        e1[1] * e2[2] - e1[2] * e2[1],
        e1[2] * e2[0] - e1[0] * e2[2],
        e1[0] * e2[1] - e1[1] * e2[0],
      ];
      final dot =
          cross[0] * v[o + 3] + cross[1] * v[o + 4] + cross[2] * v[o + 5];
      expect(dot, greaterThan(0));
    }
  });

  // Private model, only present on machines that have it (git-ignored).
  final badge = File('example/assets/local/yia_top1_badge.glb');
  test('parses the badge model', skip: !badge.existsSync(), () {
    final model = parseGlb(badge.readAsBytesSync());
    expect(model.primitives, hasLength(3)); // one per material
    expect(model.primitives.every((p) => p.metallic == 1 && p.roughness == 1),
        isTrue);
    expect(model.primitives.every((p) => p.texture != null), isTrue);
    // Face materials have normal maps; every material has a metal-rough map.
    expect(
        model.primitives.where((p) => p.normalTexture != null), hasLength(2));
    expect(model.primitives.every((p) => p.metallicRoughnessTexture != null),
        isTrue);
    expect(model.primitives.first.clearcoat, closeTo(0.35, 1e-6));
    expect(_maxRadius(model), closeTo(1, 1e-5));
  });

  test('rejects garbage and compressed files', () {
    expect(() => parseGlb(Uint8List(64)), throwsA(isA<GlbFormatException>()));

    final json = '{"asset":{"version":"2.0"},'
        '"extensionsRequired":["KHR_draco_mesh_compression"],'
        '"meshes":[{"primitives":[]}]}';
    final padded = json.padRight((json.length + 3) & ~3);
    final bytes = BytesBuilder()
      ..add(_u32(0x46546C67))
      ..add(_u32(2))
      ..add(_u32(12 + 8 + padded.length))
      ..add(_u32(padded.length))
      ..add(_u32(0x4E4F534A))
      ..add(padded.codeUnits);
    expect(
      () => parseGlb(bytes.toBytes()),
      throwsA(isA<GlbFormatException>()
          .having((e) => e.message, 'message', contains('Draco'))),
    );
  });
}

Uint8List _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
