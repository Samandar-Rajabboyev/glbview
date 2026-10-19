import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glbview/glbview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.samandar/glbview');
  final cube = File('example/assets/cube.glb').readAsBytesSync();
  late List<Map<Object?, Object?>> cameras;

  setUp(() {
    cameras = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          return 1;
        case 'setCamera':
          cameras.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Pumps a view and waits for the (real-isolate) parse to finish.
  Future<void> pumpView(WidgetTester tester, Widget view) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 500),
        ));
    await tester.pumpAndSettle();
    cameras.clear();
  }

  GlbView view(Set<GlbGesture> gestures, String key) => GlbView.memory(
        cube,
        key: ValueKey(key), // fresh state (camera) per case
        cacheKey: key,
        autoRotate: false,
        initialYaw: 0,
        initialPitch: 0,
        gestures: gestures,
      );

  Future<void> drag(WidgetTester tester, Offset by) async {
    await tester.drag(find.byType(GlbView), by);
    await tester.pumpAndSettle();
  }

  testWidgets('rotate only changes yaw, tilt only changes pitch',
      (tester) async {
    await pumpView(tester, view({GlbGesture.rotate}, 'r'));
    await drag(tester, const Offset(100, 100));
    expect(cameras.last['yaw'], isNot(0));
    expect(cameras.last['pitch'], 0);

    await pumpView(tester, view({GlbGesture.tilt}, 't'));
    await drag(tester, const Offset(100, 100));
    expect(cameras.last['yaw'], 0);
    expect(cameras.last['pitch'], isNot(0));
  });

  testWidgets('orbit changes both; none ignores touch', (tester) async {
    await pumpView(tester, view(GlbGesture.orbit, 'o'));
    await drag(tester, const Offset(100, 100));
    expect(cameras.last['yaw'], isNot(0));
    expect(cameras.last['pitch'], isNot(0));

    await pumpView(tester, view(GlbGesture.none, 'n'));
    await drag(tester, const Offset(100, 100));
    expect(cameras, isEmpty);
  });

  testWidgets('rotate-only view lets a vertical list scroll', (tester) async {
    final controller = ScrollController();
    await pumpView(
      tester,
      ListView(
        controller: controller,
        children: [
          view({GlbGesture.rotate}, 's'),
          const SizedBox(height: 2000),
        ],
      ),
    );
    await drag(tester, const Offset(0, -200));
    expect(controller.offset, greaterThan(0));
    expect(cameras, isEmpty);
  });
}
