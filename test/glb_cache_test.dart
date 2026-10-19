import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glbview/src/glb_cache.dart';

void main() {
  test('asset keys include the package', () {
    expect(GlbCache.assetKey('a.glb', null), 'asset:a.glb');
    expect(GlbCache.assetKey('a.glb', 'pkg'), 'asset:packages/pkg/a.glb');
  });

  test('memory keys follow the buffer object or an explicit key', () {
    final a = Uint8List(4);
    final b = Uint8List(4); // same contents, different object
    expect(GlbCache.memoryKey(a, null), GlbCache.memoryKey(a, null));
    expect(GlbCache.memoryKey(a, null), isNot(GlbCache.memoryKey(b, null)));
    expect(GlbCache.memoryKey(a, 'x'), GlbCache.memoryKey(b, 'x'));
  });
}
