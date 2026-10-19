import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Floats per interleaved vertex: position(3) normal(3) uv(2) tangent(4).
///
/// The tangent's `w` is the bitangent sign: `B = cross(N, T.xyz) * T.w`.
const int kFloatsPerVertex = 12;

/// Thrown when a GLB file is malformed or uses an unsupported feature.
class GlbFormatException implements Exception {
  GlbFormatException(this.message);

  final String message;

  @override
  String toString() => 'GlbFormatException: $message';
}

/// One draw call worth of GPU-ready data.
class GlbPrimitive {
  GlbPrimitive({
    required this.vertices,
    required this.indices,
    required this.baseColor,
    this.texture,
    this.metallic = 0,
    this.roughness = 0.5,
    this.normalTexture,
    this.normalScale = 1,
    this.metallicRoughnessTexture,
    this.clearcoat = 0,
    this.materialName,
  });

  /// Unique vertices, interleaved `position(3) normal(3) uv(2) tangent(4)`
  /// (see [kFloatsPerVertex]).
  final Float32List vertices;

  /// Triangle list into [vertices], counter-clockwise front faces.
  final Uint32List indices;

  /// RGBA base color factor (linear).
  final Float32List baseColor;

  /// Encoded PNG/JPEG bytes of the base color texture, if any.
  final Uint8List? texture;

  /// glTF `metallicFactor` (1 by default for materials, 0 without one).
  final double metallic;

  /// glTF `roughnessFactor` (1 by default for materials, 0.5 without one).
  final double roughness;

  /// Encoded tangent-space normal map (glTF convention: +Y green up).
  final Uint8List? normalTexture;

  /// glTF `normalTexture.scale`.
  final double normalScale;

  /// Encoded glTF metallic-roughness map (G = roughness, B = metallic).
  final Uint8List? metallicRoughnessTexture;

  /// `KHR_materials_clearcoat.clearcoatFactor`, 0 if absent.
  final double clearcoat;

  /// The glTF material's `name`, or null for unnamed materials and geometry
  /// without a material. Primitives sharing a material are merged, so names
  /// are unique within a model unless the file reuses one.
  final String? materialName;

  int get vertexCount => vertices.length ~/ kFloatsPerVertex;

  int get triangleCount => indices.length ~/ 3;

  /// A copy with the given material inputs replaced. Geometry is shared, not
  /// copied.
  GlbPrimitive copyWith({
    Float32List? baseColor,
    Uint8List? texture,
    Uint8List? normalTexture,
    Uint8List? metallicRoughnessTexture,
  }) {
    return GlbPrimitive(
      vertices: vertices,
      indices: indices,
      baseColor: baseColor ?? this.baseColor,
      texture: texture ?? this.texture,
      metallic: metallic,
      roughness: roughness,
      normalTexture: normalTexture ?? this.normalTexture,
      normalScale: normalScale,
      metallicRoughnessTexture:
          metallicRoughnessTexture ?? this.metallicRoughnessTexture,
      clearcoat: clearcoat,
      materialName: materialName,
    );
  }
}

/// A model flattened into world space, centered at the origin and scaled so
/// its bounding sphere has radius 1.
class GlbModel {
  GlbModel(this.primitives);

  final List<GlbPrimitive> primitives;

  int get vertexCount => primitives.fold(0, (sum, p) => sum + p.vertexCount);

  int get triangleCount =>
      primitives.fold(0, (sum, p) => sum + p.triangleCount);
}

const int _magicGltf = 0x46546C67;
const int _chunkJson = 0x4E4F534A;
const int _chunkBin = 0x004E4942;

const Set<String> _compressionExtensions = {
  'KHR_draco_mesh_compression',
  'EXT_meshopt_compression',
  'KHR_meshopt_compression',
};

/// Parses a binary glTF 2.0 file into flat, GPU-ready triangle data.
///
/// This is pure Dart and synchronous; run it with `Isolate.run` for large
/// files.
GlbModel parseGlb(Uint8List bytes) => _GlbParser(bytes).parse();

class _GlbParser {
  _GlbParser(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;

  late final Map<String, dynamic> json;
  Uint8List? bin;

  final Map<int, Uint8List> _bufferCache = {};

  GlbModel parse() {
    _readContainer();
    _checkExtensions();

    final nodes = _list(json['nodes']);
    final meshes = _list(json['meshes']);
    if (meshes.isEmpty) {
      throw GlbFormatException('GLB contains no meshes');
    }

    // Collects triangles grouped by material so each material is one draw.
    final groups = <int, _Group>{};

    void emitMesh(int meshIndex, _Mat4 world) {
      final mesh = _map(_at(meshes, meshIndex, 'mesh'));
      for (final p in _list(mesh['primitives'])) {
        _emitPrimitive(_map(p), world, groups);
      }
    }

    final roots = _sceneRoots(nodes);
    if (nodes.isEmpty) {
      // No node hierarchy at all: draw every mesh untransformed.
      for (var i = 0; i < meshes.length; i++) {
        emitMesh(i, _Mat4.identity());
      }
    } else {
      final visiting = <int>{};
      void walk(int index, _Mat4 parent, int depth) {
        if (depth > 256 || !visiting.add(index)) {
          throw GlbFormatException('Node hierarchy contains a cycle');
        }
        final node = _map(_at(nodes, index, 'node'));
        final world = parent.multiply(_localTransform(node));
        final mesh = node['mesh'];
        if (mesh is int) emitMesh(mesh, world);
        for (final child in _list(node['children'])) {
          walk(_int(child, 'node child'), world, depth + 1);
        }
        visiting.remove(index);
      }

      for (final r in roots) {
        walk(r, _Mat4.identity(), 0);
      }
    }

    final primitives = <GlbPrimitive>[];
    for (final entry in groups.entries) {
      final g = entry.value;
      if (g.indices.length == 0) continue;
      final material = _material(entry.key);
      primitives.add(GlbPrimitive(
        vertices: g.vertices.toList(),
        indices: g.indices.toList(),
        baseColor: material.color,
        texture: material.texture,
        metallic: material.metallic,
        roughness: material.roughness,
        normalTexture: material.normalTexture,
        normalScale: material.normalScale,
        metallicRoughnessTexture: material.metallicRoughnessTexture,
        clearcoat: material.clearcoat,
        materialName: material.name,
      ));
    }
    if (primitives.isEmpty) {
      throw GlbFormatException('GLB contains no triangle geometry');
    }
    _normalize(primitives);
    return GlbModel(primitives);
  }

  // ---------------------------------------------------------------------------
  // Container

  void _readContainer() {
    if (bytes.length < 20) {
      throw GlbFormatException('File too small to be a GLB');
    }
    if (data.getUint32(0, Endian.little) != _magicGltf) {
      throw GlbFormatException('Not a GLB file (bad magic)');
    }
    final version = data.getUint32(4, Endian.little);
    if (version != 2) {
      throw GlbFormatException('Unsupported glTF version $version (need 2)');
    }
    final total = math.min(data.getUint32(8, Endian.little), bytes.length);

    Map<String, dynamic>? parsedJson;
    var offset = 12;
    while (offset + 8 <= total) {
      final length = data.getUint32(offset, Endian.little);
      final type = data.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      final end = start + length;
      if (end > total) {
        throw GlbFormatException('Chunk exceeds file length');
      }
      if (type == _chunkJson && parsedJson == null) {
        final text = utf8.decode(Uint8List.sublistView(bytes, start, end));
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) {
          throw GlbFormatException('JSON chunk is not an object');
        }
        parsedJson = decoded;
      } else if (type == _chunkBin && bin == null) {
        bin = Uint8List.sublistView(bytes, start, end);
      }
      offset = end + ((4 - length % 4) % 4);
    }
    if (parsedJson == null) {
      throw GlbFormatException('GLB has no JSON chunk');
    }
    json = parsedJson;
  }

  void _checkExtensions() {
    final required = _list(json['extensionsRequired']).whereType<String>();
    final compressed = required.where(_compressionExtensions.contains).toList();
    if (compressed.isNotEmpty) {
      throw GlbFormatException(
          'Compressed geometry is not supported (${compressed.join(', ')}). '
          'Re-export the model without Draco/meshopt compression.');
    }
  }

  List<int> _sceneRoots(List<dynamic> nodes) {
    final scenes = _list(json['scenes']);
    if (scenes.isNotEmpty) {
      final index = json['scene'] is int ? json['scene'] as int : 0;
      final scene = _map(_at(scenes, index, 'scene'));
      return _list(scene['nodes']).map((n) => _int(n, 'scene node')).toList();
    }
    // No scenes: every node that is nobody's child is a root.
    final children = <int>{};
    for (final n in nodes) {
      for (final c in _list(_map(n)['children'])) {
        children.add(_int(c, 'node child'));
      }
    }
    return [
      for (var i = 0; i < nodes.length; i++)
        if (!children.contains(i)) i,
    ];
  }

  // ---------------------------------------------------------------------------
  // Geometry

  void _emitPrimitive(
      Map<String, dynamic> prim, _Mat4 world, Map<int, _Group> groups) {
    final mode = prim['mode'] is int ? prim['mode'] as int : 4;
    if (mode != 4 && mode != 5 && mode != 6) {
      return; // Points and lines are ignored.
    }
    if (prim['extensions'] is Map) {
      final ext = (prim['extensions'] as Map).keys.toSet();
      final hit = ext.intersection(_compressionExtensions);
      if (hit.isNotEmpty) {
        throw GlbFormatException(
            'Compressed geometry is not supported (${hit.join(', ')})');
      }
    }

    final attributes = _map(prim['attributes']);
    final posIndex = attributes['POSITION'];
    if (posIndex is! int) return;

    final positions = _readAccessor(posIndex, 3);
    final vertexCount = positions.length ~/ 3;
    final normalIndex = attributes['NORMAL'];
    final normals = normalIndex is int ? _readAccessor(normalIndex, 3) : null;
    final uvIndex = attributes['TEXCOORD_0'];
    final uvs = uvIndex is int ? _readAccessor(uvIndex, 2) : null;

    List<int> indices;
    final indicesIndex = prim['indices'];
    if (indicesIndex is int) {
      indices = _readIndices(indicesIndex);
      for (final i in indices) {
        if (i >= vertexCount) {
          throw GlbFormatException('Index $i out of range ($vertexCount)');
        }
      }
    } else {
      indices = List<int>.generate(vertexCount, (i) => i);
    }
    indices = _toTriangleList(indices, mode);
    if (indices.length < 3) return;

    final normalMatrix = world.normalMatrix();
    final flipWinding = world.determinant3() < 0;

    // Tangents: from the file when present, else accumulated per vertex from
    // UV derivatives (smooth across shared vertices).
    final tangentIndex = attributes['TANGENT'];
    final fileTangents =
        tangentIndex is int ? _readAccessor(tangentIndex, 4) : null;
    Float64List? accT, accB;
    final triTB = Float64List(6);
    if (fileTangents == null && uvs != null && normals != null) {
      accT = Float64List(vertexCount * 3);
      accB = Float64List(vertexCount * 3);
      for (var t = 0; t + 2 < indices.length; t += 3) {
        final i0 = indices[t], i1 = indices[t + 1], i2 = indices[t + 2];
        if (!_triangleTangent(positions, uvs, i0, i1, i2, triTB)) continue;
        for (final v in [i0, i1, i2]) {
          for (var c = 0; c < 3; c++) {
            accT[v * 3 + c] += triTB[c];
            accB[v * 3 + c] += triTB[3 + c];
          }
        }
      }
    }
    final material = prim['material'] is int ? prim['material'] as int : -1;
    final group = groups.putIfAbsent(material, _Group.new);
    final p = Float64List(3);
    final n = Float64List(3);

    if (normals != null) {
      // Indexed: every source vertex is transformed once and the triangles
      // reference it, instead of repeating it for each corner.
      final base = group.vertexCount;
      group.vertices.reserve(vertexCount * kFloatsPerVertex);
      for (var v = 0; v < vertexCount; v++) {
        world.transformPoint(positions, v * 3, p, 0);
        normalMatrix.transformNormal(normals, v * 3, n);
        double tx = 0, ty = 0, tz = 0, w = 1;
        if (fileTangents != null) {
          tx = fileTangents[v * 4];
          ty = fileTangents[v * 4 + 1];
          tz = fileTangents[v * 4 + 2];
          w = fileTangents[v * 4 + 3] < 0 ? -1 : 1;
        } else if (accT != null) {
          tx = accT[v * 3];
          ty = accT[v * 3 + 1];
          tz = accT[v * 3 + 2];
          w = _bitangentSign(normals[v * 3], normals[v * 3 + 1],
              normals[v * 3 + 2], tx, ty, tz, accB!, v * 3);
        }
        _addVertex(group.vertices, world, p, n, uvs, v, tx, ty, tz,
            flipWinding ? -w : w);
      }
      group.indices.reserve(indices.length);
      for (var t = 0; t + 2 < indices.length; t += 3) {
        group.indices.add(base + indices[t]);
        group.indices.add(base + indices[flipWinding ? t + 2 : t + 1]);
        group.indices.add(base + indices[flipWinding ? t + 1 : t + 2]);
      }
      return;
    }

    // No normals: flat shading needs a separate vertex per triangle corner.
    group.vertices.reserve(indices.length * kFloatsPerVertex);
    group.indices.reserve(indices.length);
    final tri = Float64List(9);
    final order = Int32List(3);
    for (var t = 0; t + 2 < indices.length; t += 3) {
      order[0] = indices[t];
      order[1] = indices[flipWinding ? t + 2 : t + 1];
      order[2] = indices[flipWinding ? t + 1 : t + 2];
      for (var k = 0; k < 3; k++) {
        world.transformPoint(positions, order[k] * 3, tri, k * 3);
      }

      final ax = tri[3] - tri[0], ay = tri[4] - tri[1], az = tri[5] - tri[2];
      final bx = tri[6] - tri[0], by = tri[7] - tri[1], bz = tri[8] - tri[2];
      var fnx = ay * bz - az * by;
      var fny = az * bx - ax * bz;
      var fnz = ax * by - ay * bx;
      final len = math.sqrt(fnx * fnx + fny * fny + fnz * fnz);
      if (len > 0) {
        fnx /= len;
        fny /= len;
        fnz /= len;
      } else {
        fnz = 1;
      }
      n[0] = fnx;
      n[1] = fny;
      n[2] = fnz;

      // Per-triangle tangent, in object space.
      double tx = 0, ty = 0, tz = 0, w = 1;
      if (fileTangents == null &&
          uvs != null &&
          _triangleTangent(positions, uvs, indices[t], indices[t + 1],
              indices[t + 2], triTB)) {
        tx = triTB[0];
        ty = triTB[1];
        tz = triTB[2];
        // Object-space face normal for the handedness test.
        final q = positions;
        final a = indices[t] * 3,
            b = indices[t + 1] * 3,
            c = indices[t + 2] * 3;
        final e1x = q[b] - q[a],
            e1y = q[b + 1] - q[a + 1],
            e1z = q[b + 2] - q[a + 2];
        final e2x = q[c] - q[a],
            e2y = q[c + 1] - q[a + 1],
            e2z = q[c + 2] - q[a + 2];
        w = _bitangentSign(e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z,
            e1x * e2y - e1y * e2x, tx, ty, tz, triTB, 3);
      }
      for (var k = 0; k < 3; k++) {
        final v = order[k];
        if (fileTangents != null) {
          tx = fileTangents[v * 4];
          ty = fileTangents[v * 4 + 1];
          tz = fileTangents[v * 4 + 2];
          w = fileTangents[v * 4 + 3] < 0 ? -1 : 1;
        }
        p[0] = tri[k * 3];
        p[1] = tri[k * 3 + 1];
        p[2] = tri[k * 3 + 2];
        group.indices.add(group.vertexCount);
        _addVertex(group.vertices, world, p, n, uvs, v, tx, ty, tz,
            flipWinding ? -w : w);
      }
    }
  }

  /// Bitangent sign from an object-space normal, tangent and the bitangent
  /// along +v at `b[bo..bo+2]`. glTF UVs run top-down while the normal map's
  /// green points up, so the bitangent is along -v.
  static double _bitangentSign(double nx, double ny, double nz, double tx,
      double ty, double tz, Float64List b, int bo) {
    final cx = ny * tz - nz * ty,
        cy = nz * tx - nx * tz,
        cz = nx * ty - ny * tx;
    final d = cx * b[bo] + cy * b[bo + 1] + cz * b[bo + 2];
    return d < 0 ? 1 : -1;
  }

  /// Appends one interleaved vertex. [p] and [n] are already in world space;
  /// the object-space tangent is transformed and made perpendicular to [n].
  static void _addVertex(
      _Builder out,
      _Mat4 world,
      Float64List p,
      Float64List n,
      Float64List? uvs,
      int v,
      double tx,
      double ty,
      double tz,
      double w) {
    out.add(p[0]);
    out.add(p[1]);
    out.add(p[2]);
    out.add(n[0]);
    out.add(n[1]);
    out.add(n[2]);
    if (uvs != null) {
      out.add(uvs[v * 2]);
      out.add(uvs[v * 2 + 1]);
    } else {
      out.add(0);
      out.add(0);
    }
    final m = world.m;
    final t0 = m[0] * tx + m[4] * ty + m[8] * tz;
    final t1 = m[1] * tx + m[5] * ty + m[9] * tz;
    final t2 = m[2] * tx + m[6] * ty + m[10] * tz;
    // Gram-Schmidt against the world normal; any perpendicular if degenerate.
    final dn = t0 * n[0] + t1 * n[1] + t2 * n[2];
    var ox = t0 - n[0] * dn, oy = t1 - n[1] * dn, oz = t2 - n[2] * dn;
    var len = math.sqrt(ox * ox + oy * oy + oz * oz);
    if (len < 1e-8) {
      // cross(n, axis) with the axis least aligned to n.
      if (n[0].abs() < 0.9) {
        ox = 0;
        oy = n[2];
        oz = -n[1];
      } else {
        ox = -n[2];
        oy = 0;
        oz = n[0];
      }
      len = math.sqrt(ox * ox + oy * oy + oz * oz);
    }
    out.add(ox / len);
    out.add(oy / len);
    out.add(oz / len);
    out.add(w);
  }

  /// Unnormalized tangent (along +u) and bitangent (along +v) of a triangle
  /// into `out[0..2]` and `out[3..5]`. False for degenerate UVs.
  static bool _triangleTangent(
      Float64List p, Float64List uv, int i0, int i1, int i2, Float64List out) {
    final e1x = p[i1 * 3] - p[i0 * 3],
        e1y = p[i1 * 3 + 1] - p[i0 * 3 + 1],
        e1z = p[i1 * 3 + 2] - p[i0 * 3 + 2];
    final e2x = p[i2 * 3] - p[i0 * 3],
        e2y = p[i2 * 3 + 1] - p[i0 * 3 + 1],
        e2z = p[i2 * 3 + 2] - p[i0 * 3 + 2];
    final du1 = uv[i1 * 2] - uv[i0 * 2], dv1 = uv[i1 * 2 + 1] - uv[i0 * 2 + 1];
    final du2 = uv[i2 * 2] - uv[i0 * 2], dv2 = uv[i2 * 2 + 1] - uv[i0 * 2 + 1];
    final det = du1 * dv2 - du2 * dv1;
    if (det.abs() < 1e-12) return false;
    final r = 1 / det;
    out[0] = (e1x * dv2 - e2x * dv1) * r;
    out[1] = (e1y * dv2 - e2y * dv1) * r;
    out[2] = (e1z * dv2 - e2z * dv1) * r;
    out[3] = (e2x * du1 - e1x * du2) * r;
    out[4] = (e2y * du1 - e1y * du2) * r;
    out[5] = (e2z * du1 - e1z * du2) * r;
    return true;
  }

  static List<int> _toTriangleList(List<int> idx, int mode) {
    if (mode == 4) return idx;
    final out = <int>[];
    if (mode == 5) {
      // Triangle strip: alternate winding so every triangle faces the same way.
      for (var i = 0; i + 2 < idx.length; i++) {
        if (i.isEven) {
          out.addAll([idx[i], idx[i + 1], idx[i + 2]]);
        } else {
          out.addAll([idx[i + 1], idx[i], idx[i + 2]]);
        }
      }
    } else {
      // Triangle fan.
      for (var i = 1; i + 1 < idx.length; i++) {
        out.addAll([idx[0], idx[i], idx[i + 1]]);
      }
    }
    return out;
  }

  /// Normalizes the model: center on its bounding box, scale to unit sphere.
  static void _normalize(List<GlbPrimitive> primitives) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    for (final p in primitives) {
      final v = p.vertices;
      for (var i = 0; i < v.length; i += kFloatsPerVertex) {
        minX = math.min(minX, v[i]);
        maxX = math.max(maxX, v[i]);
        minY = math.min(minY, v[i + 1]);
        maxY = math.max(maxY, v[i + 1]);
        minZ = math.min(minZ, v[i + 2]);
        maxZ = math.max(maxZ, v[i + 2]);
      }
    }
    final cx = (minX + maxX) / 2,
        cy = (minY + maxY) / 2,
        cz = (minZ + maxZ) / 2;
    var r2 = 0.0;
    for (final p in primitives) {
      final v = p.vertices;
      for (var i = 0; i < v.length; i += kFloatsPerVertex) {
        final dx = v[i] - cx, dy = v[i + 1] - cy, dz = v[i + 2] - cz;
        r2 = math.max(r2, dx * dx + dy * dy + dz * dz);
      }
    }
    final radius = math.sqrt(r2);
    final scale = radius > 0 && radius.isFinite ? 1 / radius : 1.0;
    for (final p in primitives) {
      final v = p.vertices;
      for (var i = 0; i < v.length; i += kFloatsPerVertex) {
        v[i] = (v[i] - cx) * scale;
        v[i + 1] = (v[i + 1] - cy) * scale;
        v[i + 2] = (v[i + 2] - cz) * scale;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Accessors

  static const Map<String, int> _componentsPerType = {
    'SCALAR': 1,
    'VEC2': 2,
    'VEC3': 3,
    'VEC4': 4,
    'MAT2': 4,
    'MAT3': 9,
    'MAT4': 16,
  };

  static int _componentSize(int componentType) => switch (componentType) {
        5120 || 5121 => 1,
        5122 || 5123 => 2,
        5125 || 5126 => 4,
        _ => throw GlbFormatException(
            'Unsupported accessor componentType $componentType'),
      };

  /// Reads the first [want] components of each element as doubles, applying
  /// `normalized` conversion. Returns `count * want` values.
  Float64List _readAccessor(int index, int want) {
    final acc = _map(_at(_list(json['accessors']), index, 'accessor'));
    if (acc['sparse'] != null) {
      throw GlbFormatException('Sparse accessors are not supported');
    }
    final count = _int(acc['count'], 'accessor.count');
    final type = acc['type'];
    final comps = _componentsPerType[type] ??
        (throw GlbFormatException('Unknown accessor type $type'));
    final componentType = _int(acc['componentType'], 'componentType');
    final normalized = acc['normalized'] == true;
    final out = Float64List(count * want);

    final viewIndex = acc['bufferView'];
    if (viewIndex is! int) return out; // No bufferView: all zeros.

    final view = _map(_at(_list(json['bufferViews']), viewIndex, 'bufferView'));
    final buffer = _buffer(_int(view['buffer'], 'bufferView.buffer'));
    final viewOffset = _intOr(view['byteOffset'], 0);
    final viewLength = _int(view['byteLength'], 'bufferView.byteLength');
    final accOffset = _intOr(acc['byteOffset'], 0);
    final size = _componentSize(componentType);
    final elementSize = size * comps;
    final stride = _intOr(view['byteStride'], 0) > 0
        ? view['byteStride'] as int
        : elementSize;

    if (count > 0) {
      final last = viewOffset + accOffset + (count - 1) * stride + elementSize;
      if (last > viewOffset + viewLength || last > buffer.length) {
        throw GlbFormatException('Accessor $index reads past its buffer');
      }
    }

    final bd = ByteData.sublistView(buffer);
    final n = math.min(want, comps);
    for (var i = 0; i < count; i++) {
      final base = viewOffset + accOffset + i * stride;
      for (var c = 0; c < n; c++) {
        final o = base + c * size;
        out[i * want + c] = switch (componentType) {
          5126 => bd.getFloat32(o, Endian.little),
          5120 => normalized
              ? math.max(bd.getInt8(o) / 127.0, -1.0)
              : bd.getInt8(o).toDouble(),
          5121 =>
            normalized ? bd.getUint8(o) / 255.0 : bd.getUint8(o).toDouble(),
          5122 => normalized
              ? math.max(bd.getInt16(o, Endian.little) / 32767.0, -1.0)
              : bd.getInt16(o, Endian.little).toDouble(),
          5123 => normalized
              ? bd.getUint16(o, Endian.little) / 65535.0
              : bd.getUint16(o, Endian.little).toDouble(),
          _ => bd.getUint32(o, Endian.little).toDouble(),
        };
      }
    }
    return out;
  }

  List<int> _readIndices(int index) {
    final acc = _map(_at(_list(json['accessors']), index, 'accessor'));
    final type = _int(acc['componentType'], 'componentType');
    if (type != 5121 && type != 5123 && type != 5125) {
      throw GlbFormatException('Unsupported index componentType $type');
    }
    final values = _readAccessor(index, 1);
    return List<int>.generate(values.length, (i) => values[i].toInt());
  }

  Uint8List _buffer(int index) {
    final cached = _bufferCache[index];
    if (cached != null) return cached;
    final buffers = _list(json['buffers']);
    final buf = _map(_at(buffers, index, 'buffer'));
    final uri = buf['uri'];
    Uint8List result;
    if (uri == null) {
      result = bin ??
          (throw GlbFormatException(
              'Buffer $index has no data (no BIN chunk)'));
    } else if (uri is String && uri.startsWith('data:')) {
      result = _decodeDataUri(uri);
    } else {
      throw GlbFormatException(
          'External buffer "$uri" is not supported; use a self-contained GLB');
    }
    return _bufferCache[index] = result;
  }

  static Uint8List _decodeDataUri(String uri) {
    final comma = uri.indexOf(',');
    if (comma < 0 || !uri.substring(0, comma).endsWith(';base64')) {
      throw GlbFormatException('Unsupported data URI');
    }
    return base64.decode(uri.substring(comma + 1));
  }

  // ---------------------------------------------------------------------------
  // Materials

  _Material _material(int index) {
    final color = Float32List.fromList([1, 1, 1, 1]);
    if (index < 0) return _Material(color, metallic: 0, roughness: 0.5);
    final mat = _map(_at(_list(json['materials']), index, 'material'));
    final pbr = _map(mat['pbrMetallicRoughness']);
    final factor = _list(pbr['baseColorFactor']);
    for (var i = 0; i < 4 && i < factor.length; i++) {
      final f = factor[i];
      if (f is num) color[i] = f.toDouble();
    }
    Uint8List? texture;
    final texInfo = pbr['baseColorTexture'];
    if (texInfo is Map && texInfo['index'] is int) {
      texture = _textureBytes(texInfo['index'] as int);
    }
    Uint8List? textureOf(dynamic info) => info is Map && info['index'] is int
        ? _textureBytes(info['index'] as int)
        : null;
    final normalInfo = mat['normalTexture'];
    final scale = normalInfo is Map ? normalInfo['scale'] : null;
    final clearcoat = _map(
        _map(mat['extensions'])['KHR_materials_clearcoat'])['clearcoatFactor'];
    // Per the glTF spec both factors default to 1.
    final metallic = pbr['metallicFactor'];
    final roughness = pbr['roughnessFactor'];
    return _Material(
      color,
      texture: texture,
      metallic: metallic is num ? metallic.toDouble().clamp(0.0, 1.0) : 1.0,
      roughness: roughness is num ? roughness.toDouble().clamp(0.0, 1.0) : 1.0,
      normalTexture: textureOf(normalInfo),
      normalScale: scale is num ? scale.toDouble() : 1.0,
      metallicRoughnessTexture: textureOf(pbr['metallicRoughnessTexture']),
      clearcoat: clearcoat is num ? clearcoat.toDouble().clamp(0.0, 1.0) : 0.0,
      name: mat['name'] is String ? mat['name'] as String : null,
    );
  }

  /// Returns encoded image bytes, or null when the image can't be used
  /// (e.g. KTX2/Basis textures that native image decoders can't read).
  Uint8List? _textureBytes(int textureIndex) {
    final textures = _list(json['textures']);
    if (textureIndex >= textures.length) return null;
    final tex = _map(textures[textureIndex]);
    var source = tex['source'];
    final ext = _map(tex['extensions']);
    for (final name in const ['EXT_texture_webp', 'EXT_texture_avif']) {
      final s = _map(ext[name])['source'];
      if (source is! int && s is int) source = s;
    }
    if (source is! int) return null;
    final images = _list(json['images']);
    if (source >= images.length) return null;
    final image = _map(images[source]);
    final mime = image['mimeType'];
    if (mime is String && mime.contains('ktx')) return null;

    Uint8List? bytes;
    final viewIndex = image['bufferView'];
    final uri = image['uri'];
    if (viewIndex is int) {
      final view =
          _map(_at(_list(json['bufferViews']), viewIndex, 'bufferView'));
      final buffer = _buffer(_int(view['buffer'], 'bufferView.buffer'));
      final offset = _intOr(view['byteOffset'], 0);
      final length = _int(view['byteLength'], 'bufferView.byteLength');
      if (offset + length > buffer.length) {
        throw GlbFormatException('Image $source reads past its buffer');
      }
      // Copy so the result doesn't keep the whole file alive.
      bytes = Uint8List.fromList(
          Uint8List.sublistView(buffer, offset, offset + length));
    } else if (uri is String && uri.startsWith('data:')) {
      bytes = _decodeDataUri(uri);
    }
    if (bytes == null || bytes.length < 4) return null;
    // Basis/KTX2 magic: «KTX
    if (bytes[0] == 0xAB && bytes[1] == 0x4B && bytes[2] == 0x54) return null;
    return bytes;
  }

  // ---------------------------------------------------------------------------
  // Nodes

  static _Mat4 _localTransform(Map<String, dynamic> node) {
    final matrix = _list(node['matrix']);
    if (matrix.length == 16) {
      return _Mat4(Float64List.fromList(
          [for (final v in matrix) (v as num).toDouble()]));
    }
    final t = _vec(node['translation'], const [0, 0, 0]);
    final r = _vec(node['rotation'], const [0, 0, 0, 1]);
    final s = _vec(node['scale'], const [1, 1, 1]);
    return _Mat4.trs(t, r, s);
  }

  static List<double> _vec(dynamic v, List<double> fallback) {
    final list = _list(v);
    if (list.length != fallback.length) return fallback;
    return [for (final x in list) (x as num).toDouble()];
  }

  // ---------------------------------------------------------------------------
  // JSON helpers

  static List<dynamic> _list(dynamic v) => v is List ? v : const [];

  static Map<String, dynamic> _map(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  static dynamic _at(List<dynamic> list, int index, String what) {
    if (index < 0 || index >= list.length) {
      throw GlbFormatException('Invalid $what index $index');
    }
    return list[index];
  }

  static int _int(dynamic v, String what) {
    if (v is int) return v;
    throw GlbFormatException('Missing or invalid $what');
  }

  static int _intOr(dynamic v, int fallback) => v is int ? v : fallback;
}

class _Material {
  _Material(
    this.color, {
    this.texture,
    required this.metallic,
    required this.roughness,
    this.normalTexture,
    this.normalScale = 1,
    this.metallicRoughnessTexture,
    this.clearcoat = 0,
    this.name,
  });

  final Float32List color;
  final Uint8List? texture;
  final double metallic;
  final double roughness;
  final Uint8List? normalTexture;
  final double normalScale;
  final Uint8List? metallicRoughnessTexture;
  final double clearcoat;
  final String? name;
}

/// Geometry collected for one material.
class _Group {
  final _Builder vertices = _Builder();
  final _IndexBuilder indices = _IndexBuilder();

  int get vertexCount => vertices.length ~/ kFloatsPerVertex;
}

/// Growable uint32 buffer.
class _IndexBuilder {
  Uint32List _data = Uint32List(1024);
  int length = 0;

  void reserve(int extra) {
    final need = length + extra;
    if (need <= _data.length) return;
    var cap = _data.length;
    while (cap < need) {
      cap *= 2;
    }
    _data = Uint32List(cap)..setRange(0, length, _data);
  }

  void add(int v) => _data[length++] = v;

  Uint32List toList() => Uint32List(length)..setRange(0, length, _data);
}

/// Growable float buffer that avoids boxing.
class _Builder {
  Float32List _data = Float32List(1024);
  int length = 0;

  void reserve(int extra) {
    final need = length + extra;
    if (need <= _data.length) return;
    var cap = _data.length;
    while (cap < need) {
      cap *= 2;
    }
    final next = Float32List(cap)..setRange(0, length, _data);
    _data = next;
  }

  void add(double v) => _data[length++] = v;

  /// Exact-size copy, so the spare capacity isn't kept alive or sent.
  Float32List toList() => Float32List(length)..setRange(0, length, _data);
}

/// Column-major 4x4 matrix (glTF convention).
class _Mat4 {
  _Mat4(this.m);

  factory _Mat4.identity() => _Mat4(
      Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]));

  factory _Mat4.trs(List<double> t, List<double> q, List<double> s) {
    final x = q[0], y = q[1], z = q[2], w = q[3];
    final m = Float64List(16);
    m[0] = (1 - 2 * (y * y + z * z)) * s[0];
    m[1] = (2 * (x * y + z * w)) * s[0];
    m[2] = (2 * (x * z - y * w)) * s[0];
    m[4] = (2 * (x * y - z * w)) * s[1];
    m[5] = (1 - 2 * (x * x + z * z)) * s[1];
    m[6] = (2 * (y * z + x * w)) * s[1];
    m[8] = (2 * (x * z + y * w)) * s[2];
    m[9] = (2 * (y * z - x * w)) * s[2];
    m[10] = (1 - 2 * (x * x + y * y)) * s[2];
    m[12] = t[0];
    m[13] = t[1];
    m[14] = t[2];
    m[15] = 1;
    return _Mat4(m);
  }

  final Float64List m;

  _Mat4 multiply(_Mat4 other) {
    final a = m, b = other.m;
    final r = Float64List(16);
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[k * 4 + row] * b[col * 4 + k];
        }
        r[col * 4 + row] = sum;
      }
    }
    return _Mat4(r);
  }

  void transformPoint(Float64List src, int i, Float64List dst, int o) {
    final x = src[i], y = src[i + 1], z = src[i + 2];
    dst[o] = m[0] * x + m[4] * y + m[8] * z + m[12];
    dst[o + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
    dst[o + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
  }

  double determinant3() =>
      m[0] * (m[5] * m[10] - m[9] * m[6]) -
      m[4] * (m[1] * m[10] - m[9] * m[2]) +
      m[8] * (m[1] * m[6] - m[5] * m[2]);

  /// Inverse-transpose of the upper 3x3, as a 3x3 column-major matrix.
  _Mat3 normalMatrix() {
    final a = m[0], b = m[4], c = m[8];
    final d = m[1], e = m[5], f = m[9];
    final g = m[2], h = m[6], i = m[10];
    final det = determinant3();
    if (det.abs() < 1e-20) return _Mat3.fromUpper(m);
    final inv = 1 / det;
    // inverse (row-major cofactors / det), then transposed -> stored column-major.
    // (A^-1)^T[r][c] = cofactor(r, c) / det.
    final n = Float64List(9);
    // column 0 (r = 0..2, c = 0)
    n[0] = (e * i - f * h) * inv;
    n[1] = -(b * i - c * h) * inv;
    n[2] = (b * f - c * e) * inv;
    // column 1
    n[3] = -(d * i - f * g) * inv;
    n[4] = (a * i - c * g) * inv;
    n[5] = -(a * f - c * d) * inv;
    // column 2
    n[6] = (d * h - e * g) * inv;
    n[7] = -(a * h - b * g) * inv;
    n[8] = (a * e - b * d) * inv;
    return _Mat3(n);
  }
}

class _Mat3 {
  _Mat3(this.m);

  factory _Mat3.fromUpper(Float64List m4) => _Mat3(Float64List.fromList(
      [m4[0], m4[1], m4[2], m4[4], m4[5], m4[6], m4[8], m4[9], m4[10]]));

  final Float64List m;

  /// Transforms and normalizes the normal at `src[i..i+2]` into `dst`.
  void transformNormal(Float64List src, int i, Float64List dst) {
    final x = src[i], y = src[i + 1], z = src[i + 2];
    var nx = m[0] * x + m[3] * y + m[6] * z;
    var ny = m[1] * x + m[4] * y + m[7] * z;
    var nz = m[2] * x + m[5] * y + m[8] * z;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0) {
      nx /= len;
      ny /= len;
      nz /= len;
    } else {
      nz = 1;
    }
    dst[0] = nx;
    dst[1] = ny;
    dst[2] = nz;
  }
}
