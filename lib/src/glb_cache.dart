import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'glb_channel.dart';
import 'glb_parser.dart';

/// What a view needs to know about a model whose geometry and textures
/// already live on the GPU.
@immutable
class GlbModelInfo {
  const GlbModelInfo({
    required this.materialNames,
    required this.vertexCount,
    required this.triangleCount,
  });

  /// Material name per primitive, in native draw order.
  final List<String?> materialNames;
  final int vertexCount;
  final int triangleCount;
}

class _Entry {
  _Entry(this.ready);

  final Future<GlbModelInfo> ready;
  bool done = false;

  /// Mounted views using this model. Entries in use are never evicted.
  int refs = 0;
  int lastUsed = 0;
}

/// Process-wide cache of parsed models uploaded to the native GPU store,
/// keyed by asset or memory source. Shared by every [GlbView].
class GlbCache {
  GlbCache._();

  static final Map<String, _Entry> _entries = {};
  static int _clock = 0;
  static int _memoryKeys = 0;
  static final Expando<String> _bytesKeys = Expando('glbview.key');

  /// Unused models kept on the GPU, least recently used evicted first.
  static int maxUnusedModels = 4;

  static String assetKey(String name, String? package) =>
      package == null ? 'asset:$name' : 'asset:packages/$package/$name';

  /// A stable key for [bytes]: [cacheKey] if given, otherwise one tied to
  /// this exact buffer object.
  static String memoryKey(Uint8List bytes, String? cacheKey) {
    if (cacheKey != null) return 'mem:$cacheKey';
    return _bytesKeys[bytes] ??= 'mem#${_memoryKeys++}';
  }

  static bool isReady(String key) => _entries[key]?.done ?? false;

  /// Parses and uploads the model for [key] once; later calls share it.
  static Future<GlbModelInfo> load(
    String key,
    Future<Uint8List> Function() readBytes,
  ) {
    final existing = _entries[key];
    if (existing != null) {
      existing.lastUsed = ++_clock;
      return existing.ready;
    }
    late final _Entry entry;
    entry = _Entry(_parseAndUpload(key, readBytes).then((info) {
      entry.done = true;
      _trim();
      return info;
    }, onError: (Object e, StackTrace st) {
      // Failed loads aren't cached, so the next view retries.
      if (identical(_entries[key], entry)) _entries.remove(key);
      Error.throwWithStackTrace(e, st);
    }))
      ..lastUsed = ++_clock;
    _entries[key] = entry;
    return entry.ready;
  }

  static Future<GlbModelInfo> _parseAndUpload(
    String key,
    Future<Uint8List> Function() readBytes,
  ) async {
    final sw = Stopwatch()..start();
    final bytes = await readBytes();
    final read = sw.elapsedMilliseconds;
    final model = await _parse(bytes);
    final parsed = sw.elapsedMilliseconds;
    await GlbChannel.cacheModel(key, model, debugTimings: debugTimings);
    if (debugTimings) {
      debugPrint('GlbView timing [$key]: read ${read}ms, '
          'parse ${parsed - read}ms (${model.vertexCount} vertices, '
          '${model.triangleCount} triangles), '
          'GPU upload ${sw.elapsedMilliseconds - parsed}ms');
    }
    // Only names are kept on the Dart side; the vertex data can be freed.
    return GlbModelInfo(
      materialNames: [for (final p in model.primitives) p.materialName],
      vertexCount: model.vertexCount,
      triangleCount: model.triangleCount,
    );
  }

  // Static so the isolate closure can't capture anything else.
  static Future<GlbModel> _parse(Uint8List bytes) =>
      Isolate.run(() => parseGlb(bytes), debugName: 'glb_parse');

  static void acquire(String key) {
    final e = _entries[key];
    if (e == null) return;
    e.refs++;
    e.lastUsed = ++_clock;
  }

  static void release(String key) {
    final e = _entries[key];
    if (e == null) return;
    e.refs--;
    e.lastUsed = ++_clock;
    _trim();
  }

  static void evict(String key) {
    final e = _entries[key];
    if (e == null || e.refs > 0) return;
    _entries.remove(key);
    if (e.done) GlbChannel.evictModel(key).catchError((Object _) {});
  }

  static void clear() {
    for (final key in _entries.keys.toList()) {
      evict(key);
    }
  }

  static void _trim() {
    final unused = _entries.entries
        .where((e) => e.value.refs <= 0 && e.value.done)
        .toList()
      ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
    for (var i = 0; i < unused.length - maxUnusedModels; i++) {
      evict(unused[i].key);
    }
  }

  static bool debugTimings = false;

  /// Reads an asset as bytes.
  static Future<Uint8List> readAsset(AssetBundle bundle, String key) async {
    final data = await bundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
