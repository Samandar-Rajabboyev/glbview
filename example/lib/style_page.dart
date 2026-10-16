import 'package:flutter/material.dart';
import 'package:glbview/glbview.dart';

/// The same model rendered matte (left) and glossy (right), with live style
/// controls. Style changes are sent with `setStyle`, so the native texture is
/// never recreated while dragging the sliders.
class StylePage extends StatefulWidget {
  const StylePage({super.key});

  @override
  State<StylePage> createState() => _StylePageState();
}

const _models = {
  'Badge': 'assets/local/yia_top1_badge.glb',
  'Star': 'assets/star.glb',
  'Cube': 'assets/cube.glb',
};

class _StylePageState extends State<StylePage> {
  String _model = 'Badge';
  bool _glossy = true;
  bool _override = true;
  bool _useGradient = false;
  double _gloss = 1;
  double _sparkle = 0.5;
  double _gradientMix = 0;

  static const _gradient = [Color(0xFF7B5CFF), Color(0xFFFF6FD8)];

  Widget _view(String label, {required bool glossy, required double size}) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: const Color(0xFF15172A),
            child: GlbView.asset(
              _models[_model]!,
              // Same key per model so both views restart together.
              key: ValueKey('$_model-$label'),
              width: size,
              height: size,
              initialPitch: 0,
              glossy: glossy,
              gloss: _gloss,
              glossOverridesMaterial: _override,
              gradientColors: _useGradient ? _gradient : null,
              gradientMix: _gradientMix,
              sparkle: _sparkle,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.labelLarge),
      ],
    );
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 96, child: Text(label)),
        Expanded(
          child: Slider(value: value, onChanged: _glossy ? onChanged : null),
        ),
        SizedBox(width: 36, child: Text(value.toStringAsFixed(2))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width.clamp(280.0, 720.0);
    final size = (width - 16 * 2 - 12) / 2;
    return Scaffold(
      appBar: AppBar(title: const Text('Matte vs glossy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _view('Matte', glossy: false, size: size),
              _view(
                _glossy ? 'Glossy' : 'Glossy (off)',
                glossy: _glossy,
                size: size,
              ),
            ],
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [
              for (final name in _models.keys)
                ButtonSegment(value: name, label: Text(name)),
            ],
            selected: {_model},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _model = s.first),
          ),
          SwitchListTile(
            title: const Text('Glossy'),
            value: _glossy,
            onChanged: (v) => setState(() => _glossy = v),
          ),
          _slider('Gloss', _gloss, (v) => setState(() => _gloss = v)),
          _slider('Sparkle', _sparkle, (v) => setState(() => _sparkle = v)),
          _slider(
            'Gradient mix',
            _gradientMix,
            (v) => setState(() => _gradientMix = v),
          ),
          SwitchListTile(
            title: const Text('Gloss overrides material roughness'),
            value: _override,
            onChanged: (v) => setState(() => _override = v),
          ),
          SwitchListTile(
            title: const Text('Purple-pink gradient environment'),
            value: _useGradient,
            onChanged: (v) => setState(() => _useGradient = v),
          ),
        ],
      ),
    );
  }
}
