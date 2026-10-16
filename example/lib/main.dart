import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:glbview/glbview.dart';

import 'style_page.dart';

void main() => runApp(const GlbViewExampleApp());

class GlbViewExampleApp extends StatelessWidget {
  const GlbViewExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'glbview example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ViewerPage(),
    );
  }
}

enum Sample { cube, star, badge, broken }

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  Sample _sample = Sample.cube;
  bool _autoRotate = true;
  double _speed = 20;

  // Deliberately not a GLB, to show the error UI.
  static final Uint8List _brokenBytes = Uint8List.fromList(
    List<int>.generate(64, (i) => i),
  );

  @override
  Widget build(BuildContext context) {
    final size =
        MediaQuery.sizeOf(context).shortestSide.clamp(200.0, 420.0) - 32;

    Widget viewer = switch (_sample) {
      Sample.cube => GlbView.asset(
        'assets/cube.glb',
        key: const ValueKey('cube'),
        width: size,
        height: size,
        autoRotate: _autoRotate,
        autoRotateDegreesPerSecond: _speed,
        initialPitch: 20,
        placeholder: const _Placeholder(),
      ),
      Sample.star => GlbView.asset(
        'assets/star.glb',
        key: const ValueKey('star'),
        width: size,
        height: size,
        autoRotate: _autoRotate,
        autoRotateDegreesPerSecond: _speed,
        initialPitch: 0,
        initialDistance: 3,
        placeholder: const _Placeholder(),
      ),
      Sample.badge => GlbView.asset(
        'assets/local/yia_top1_badge.glb',
        key: const ValueKey('badge'),
        width: size,
        height: size,
        autoRotate: _autoRotate,
        autoRotateDegreesPerSecond: _speed,
        initialPitch: 0,
        placeholder: const _Placeholder(),
      ),
      Sample.broken => GlbView.memory(
        _brokenBytes,
        key: const ValueKey('broken'),
        width: size,
        height: size,
        errorBuilder: (context, error) => _ErrorCard(error: error),
      ),
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('glbview'),
        actions: [
          IconButton(
            tooltip: 'Matte vs glossy',
            icon: const Icon(Icons.auto_awesome),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const StylePage())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const RadialGradient(
                  colors: [Color(0xFF3A3F5C), Color(0xFF15172A)],
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: viewer,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Drag to orbit, pinch to zoom.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SegmentedButton<Sample>(
            segments: const [
              ButtonSegment(value: Sample.cube, label: Text('Cube')),
              ButtonSegment(value: Sample.star, label: Text('Star')),
              ButtonSegment(value: Sample.badge, label: Text('Badge')),
              ButtonSegment(value: Sample.broken, label: Text('Broken')),
            ],
            showSelectedIcon: false,
            selected: {_sample},
            onSelectionChanged: (s) => setState(() => _sample = s.first),
          ),
          SwitchListTile(
            title: const Text('Auto-rotate'),
            value: _autoRotate,
            onChanged: (v) => setState(() => _autoRotate = v),
          ),
          ListTile(
            title: Text('Speed: ${_speed.round()}°/s'),
            subtitle: Slider(
              min: 5,
              max: 120,
              value: _speed,
              onChanged: _autoRotate ? (v) => setState(() => _speed = v) : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Loading model…', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final message = error is GlbFormatException
        ? (error as GlbFormatException).message
        : '$error';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image_outlined,
              size: 48,
              color: Colors.white70,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
