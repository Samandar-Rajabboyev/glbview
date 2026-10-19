import 'dart:io';

import 'package:flutter/foundation.dart';
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

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('a two-finger pinch does not rotate or tilt ($platform)',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        for (final gestures in [
          GlbGesture.orbit,
          {GlbGesture.rotate},
          {GlbGesture.tilt},
        ]) {
          await pumpView(tester, view(gestures, 'pinch-$platform-$gestures'));
          final center = tester.getCenter(find.byType(GlbView));
          final a = await tester.startGesture(center - const Offset(20, 20));
          final b = await tester.startGesture(center + const Offset(20, 20),
              pointer: 2);
          for (var i = 0; i < 10; i++) {
            await a.moveBy(const Offset(-8, -8));
            await b.moveBy(const Offset(8, 8));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await a.up();
          await b.up();
          await tester.pumpAndSettle();
          for (final c in cameras) {
            expect(c['yaw'], 0, reason: '$gestures yaw');
            expect(c['pitch'], 0, reason: '$gestures pitch');
          }
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('lifting one of two fingers resumes the drag without a jump',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pumpView(tester, view(GlbGesture.orbit, 'lift'));
      final center = tester.getCenter(find.byType(GlbView));
      final a = await tester.startGesture(center - const Offset(60, 0));
      final b =
          await tester.startGesture(center + const Offset(60, 0), pointer: 2);
      await a.moveBy(const Offset(-30, 0));
      await b.moveBy(const Offset(30, 0));
      await tester.pump();
      await b.up();
      // One finger keeps going: 10 steps of 5 px to the right.
      for (var i = 0; i < 10; i++) {
        await a.moveBy(const Offset(5, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await tester.pumpAndSettle();
      // At most 50 px of drag at 0.4°/px; a jump would add the 60+ px gap.
      final yaw = cameras.last['yaw']! as double;
      expect(yaw, inInclusiveRange(0, 20));
      expect(cameras.last['pitch'], 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('with zoom enabled a pinch zooms and does not orbit',
      (tester) async {
    await pumpView(tester, view(GlbGesture.all, 'zoom'));
    final center = tester.getCenter(find.byType(GlbView));
    final a = await tester.startGesture(center - const Offset(20, 0));
    final b =
        await tester.startGesture(center + const Offset(20, 0), pointer: 2);
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-6, 0));
      await b.moveBy(const Offset(6, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(cameras.last['distance'], lessThan(3.2));
    expect(cameras.every((c) => c['yaw'] == 0 && c['pitch'] == 0), isTrue);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final gestures in [
      GlbGesture.all,
      GlbGesture.orbit,
      {GlbGesture.rotate},
    ]) {
      testWidgets('consecutive drags never jump ($platform, $gestures)',
          (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await pumpView(tester, view(gestures, 'seq-$platform-$gestures'));
          final center = tester.getCenter(find.byType(GlbView));
          // Three drags, each starting where the previous one did, like a
          // user swiping the badge again and again.
          for (var d = 0; d < 3; d++) {
            final g = await tester.startGesture(center - const Offset(60, 0));
            for (var i = 0; i < 12; i++) {
              await g.moveBy(Offset(d.isEven ? 10 : -10, 0));
              await tester.pump(const Duration(milliseconds: 16));
            }
            await g.up();
            await tester.pumpAndSettle();
          }
          // 10 px per step at 0.4°/px is 4°; allow slop catch-up but no
          // jump back across previous drags.
          for (var i = 1; i < cameras.length; i++) {
            final step = ((cameras[i]['yaw']! as double) -
                    (cameras[i - 1]['yaw']! as double))
                .abs();
            expect(step, lessThanOrEqualTo(8.5),
                reason: 'send $i: ${cameras[i - 1]} -> ${cameras[i]}');
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  // On iOS the first move of a new touch has been seen carrying a delta
  // measured from the previous touch's last position. Movement must come
  // from positions, never from event deltas.
  for (final gestures in [
    GlbGesture.all,
    GlbGesture.orbit,
    {GlbGesture.rotate}
  ]) {
    testWidgets('a bogus event delta does not move the model ($gestures)',
        (tester) async {
      await pumpView(tester, view(gestures, 'bogus-$gestures'));
      final center = tester.getCenter(find.byType(GlbView));
      const pointer = 7;
      var position = center;
      await tester.sendEventToBinding(
          PointerDownEvent(pointer: pointer, position: position));
      for (var i = 0; i < 12; i++) {
        final next = position + const Offset(10, 0);
        await tester.sendEventToBinding(PointerMoveEvent(
          pointer: pointer,
          position: next,
          // The first move reports a huge, wrong delta; the rest are right.
          delta: i == 0 ? const Offset(-220, 0) : next - position,
        ));
        position = next;
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.sendEventToBinding(
          PointerUpEvent(pointer: pointer, position: position));
      await tester.pumpAndSettle();
      expect(cameras, isNotEmpty);
      for (final c in cameras) {
        expect(c['yaw']! as double, inInclusiveRange(0, 50), reason: '$c');
      }
    });
  }

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
