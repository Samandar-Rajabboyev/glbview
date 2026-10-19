import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glb_channel.dart';
import 'glb_material_override.dart';
import 'glb_parser.dart';
import 'glb_style.dart';

/// Builds a widget shown when loading or rendering the model failed.
typedef GlbErrorBuilder = Widget Function(BuildContext context, Object error);

/// Displays a binary glTF 2.0 (`.glb`) model rendered natively (OpenGL ES on
/// Android, Metal on iOS) through a Flutter [Texture].
class GlbView extends StatefulWidget {
  /// Shows the GLB stored in the asset bundle under [name].
  const GlbView.asset(
    String name, {
    super.key,
    this.package,
    this.bundle,
    this.width = 300,
    this.height = 300,
    this.autoRotate = true,
    this.autoRotateDegreesPerSecond = 20,
    this.interactive = true,
    this.initialYaw = 0,
    this.initialPitch = 10,
    this.initialDistance = 3.2,
    this.placeholder,
    this.errorBuilder,
    this.glossy = true,
    this.gloss = 1.0,
    this.glossOverridesMaterial = true,
    this.gradientColors,
    this.gradientMix = 0.0,
    this.sparkle = 0.5,
    this.specularColor = const Color(0xFFFFFFFF),
    this.materialOverrides,
  })  : assetName = name,
        bytes = null;

  /// Shows a GLB held in memory.
  const GlbView.memory(
    Uint8List this.bytes, {
    super.key,
    this.width = 300,
    this.height = 300,
    this.autoRotate = true,
    this.autoRotateDegreesPerSecond = 20,
    this.interactive = true,
    this.initialYaw = 0,
    this.initialPitch = 10,
    this.initialDistance = 3.2,
    this.placeholder,
    this.errorBuilder,
    this.glossy = true,
    this.gloss = 1.0,
    this.glossOverridesMaterial = true,
    this.gradientColors,
    this.gradientMix = 0.0,
    this.sparkle = 0.5,
    this.specularColor = const Color(0xFFFFFFFF),
    this.materialOverrides,
  })  : assetName = null,
        package = null,
        bundle = null;

  final String? assetName;
  final String? package;
  final AssetBundle? bundle;
  final Uint8List? bytes;

  /// Logical size of the view.
  final double width;
  final double height;

  final bool autoRotate;
  final double autoRotateDegreesPerSecond;

  /// Whether drag-to-orbit and pinch-to-zoom are enabled.
  final bool interactive;

  /// Initial camera, in degrees, degrees and model radii.
  final double initialYaw;
  final double initialPitch;
  final double initialDistance;

  /// Shown until the first model upload finishes. Defaults to a spinner.
  final Widget? placeholder;

  /// Shown instead of the model when something fails.
  final GlbErrorBuilder? errorBuilder;

  /// Glossy "glass/candy" shading; false gives plain matte lighting.
  final bool glossy;

  /// Overall glossiness, 0..1. 1 is the full glass look.
  final double gloss;

  /// Whether [gloss] replaces the file's roughness (true) or the file's
  /// `roughnessFactor` is used (false).
  final bool glossOverridesMaterial;

  /// Optional `[top, bottom]` colors of the reflected studio environment and
  /// of the screen-space tint controlled by [gradientMix].
  final List<Color>? gradientColors;

  /// How much the screen-space gradient tints the base color, 0..1.
  final double gradientMix;

  /// Animated glitter / micro-normal strength, 0..1.
  final double sparkle;

  /// Color of specular highlights.
  final Color specularColor;

  /// Per-material replacements keyed by glTF material name, e.g. a texture
  /// generated at runtime. Changing them re-uploads the already-parsed model
  /// to the same native texture: no re-parse and no texture recreation.
  /// Keep the byte buffers identical across rebuilds (see
  /// [GlbMaterialOverride]).
  final Map<String, GlbMaterialOverride>? materialOverrides;

  GlbStyle get style {
    final colors = gradientColors;
    return GlbStyle(
      glossy: glossy,
      gloss: gloss,
      glossOverridesMaterial: glossOverridesMaterial,
      gradientTop: colors != null && colors.isNotEmpty
          ? colors.first
          : GlbStyle.defaultGradientTop,
      gradientBottom: colors != null && colors.length > 1
          ? colors[1]
          : (colors != null && colors.isNotEmpty
              ? colors.first
              : GlbStyle.defaultGradientBottom),
      gradientMix: gradientMix,
      sparkle: sparkle,
      specularColor: specularColor,
    );
  }

  static const double minPitch = -85;
  static const double maxPitch = 85;
  static const double minDistance = 1.6;
  static const double maxDistance = 10;

  @override
  State<GlbView> createState() => _GlbViewState();
}

class _GlbViewState extends State<GlbView> {
  int? _textureId;
  bool _ready = false;
  Object? _error;

  /// Bumped whenever an in-flight load becomes obsolete.
  int _generation = 0;
  double? _devicePixelRatio;

  /// Parsed model, reused when only the texture needs recreating.
  Future<GlbModel>? _model;

  /// Overrides in the last model upload, and whether a re-upload is running.
  Map<String, GlbMaterialOverride>? _sentOverrides;
  bool _overridesBusy = false;

  late double _yaw = widget.initialYaw;
  late double _pitch =
      widget.initialPitch.clamp(GlbView.minPitch, GlbView.maxPitch);
  late double _distance =
      widget.initialDistance.clamp(GlbView.minDistance, GlbView.maxDistance);
  double _scaleStartDistance = 0;

  bool _cameraBusy = false;
  bool _cameraDirty = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.of(context).devicePixelRatio;
    if (dpr != _devicePixelRatio) {
      _devicePixelRatio = dpr;
      _recreate();
    }
  }

  @override
  void didUpdateWidget(GlbView old) {
    super.didUpdateWidget(old);
    final sourceChanged = old.assetName != widget.assetName ||
        old.package != widget.package ||
        old.bundle != widget.bundle ||
        !identical(old.bytes, widget.bytes);
    if (sourceChanged) _model = null;
    if (sourceChanged ||
        old.width != widget.width ||
        old.height != widget.height ||
        old.autoRotate != widget.autoRotate ||
        old.autoRotateDegreesPerSecond != widget.autoRotateDegreesPerSecond) {
      _recreate();
    } else {
      if (old.style != widget.style) _pushStyle();
      if (!mapEquals(old.materialOverrides, widget.materialOverrides)) {
        _syncOverrides();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _releaseTexture();
    super.dispose();
  }

  void _releaseTexture() {
    final id = _textureId;
    _textureId = null;
    if (id != null) {
      GlbChannel.dispose(id).catchError((Object _) {});
    }
  }

  /// Throws away the current texture and builds a new one. Called from
  /// lifecycle methods, so state is mutated directly (a build follows).
  void _recreate() {
    final gen = ++_generation;
    _releaseTexture();
    _ready = false;
    _error = null;
    _cameraBusy = false;
    _cameraDirty = false;
    _sentOverrides = null;
    _overridesBusy = false;
    _load(gen);
  }

  Future<void> _load(int gen) async {
    final dpr = _devicePixelRatio ?? 1;
    final modelFuture = _model ??= _parse();
    // Errors are handled when awaited below; don't report them as unhandled
    // while the texture is still being created.
    modelFuture.ignore();
    try {
      final id = await GlbChannel.create(
        width: (widget.width * dpr).round().clamp(1, 4096),
        height: (widget.height * dpr).round().clamp(1, 4096),
        autoRotate: widget.autoRotate ? widget.autoRotateDegreesPerSecond : 0,
      );
      if (gen != _generation || !mounted) {
        GlbChannel.dispose(id).catchError((Object _) {});
        return;
      }
      setState(() => _textureId = id);

      final GlbModel model;
      try {
        model = await modelFuture;
      } catch (_) {
        if (identical(_model, modelFuture)) _model = null; // allow retry
        rethrow;
      }
      if (gen != _generation || !mounted) return;
      await GlbChannel.setCamera(id,
          yaw: _yaw, pitch: _pitch, distance: _distance);
      // Style goes before the model (so the first frame is right) and again
      // after it, in case the widget changed while the upload was running.
      await GlbChannel.setStyle(id, widget.style);
      await _uploadModel(id, model);
      if (gen != _generation || !mounted) return;
      await GlbChannel.setStyle(id, widget.style);
      if (gen != _generation || !mounted) return;
      setState(() => _ready = true);
      // Overrides may have changed while the first upload was running.
      _syncOverrides();
    } catch (e, st) {
      if (gen != _generation || !mounted) return;
      debugPrint('GlbView: failed to load model: $e\n$st');
      setState(() => _error = e);
    }
  }

  Future<void> _uploadModel(int id, GlbModel model) {
    final overrides = widget.materialOverrides;
    _sentOverrides = overrides;
    return GlbChannel.loadModel(id, model.withMaterialOverrides(overrides));
  }

  /// Re-uploads the cached model when the overrides differ from the last
  /// upload. Serialized, and loops until the latest overrides are sent.
  Future<void> _syncOverrides() async {
    final id = _textureId;
    final modelFuture = _model;
    if (!_ready ||
        _overridesBusy ||
        id == null ||
        modelFuture == null ||
        mapEquals(_sentOverrides, widget.materialOverrides)) {
      return;
    }
    final gen = _generation;
    _overridesBusy = true;
    try {
      await _uploadModel(id, await modelFuture);
    } catch (e, st) {
      if (gen != _generation || !mounted) return;
      debugPrint('GlbView: failed to apply material overrides: $e\n$st');
      setState(() => _error = e);
      return;
    } finally {
      if (gen == _generation) _overridesBusy = false;
    }
    if (gen == _generation && mounted) _syncOverrides();
  }

  Future<GlbModel> _parse() async {
    final Uint8List bytes;
    if (widget.bytes != null) {
      bytes = widget.bytes!;
    } else {
      final bundle = widget.bundle ?? DefaultAssetBundle.of(context);
      final key = widget.package == null
          ? widget.assetName!
          : 'packages/${widget.package}/${widget.assetName}';
      final data = await bundle.load(key);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    return _parseInIsolate(bytes);
  }

  // Static so the isolate closure can't capture this State.
  static Future<GlbModel> _parseInIsolate(Uint8List bytes) =>
      Isolate.run(() => parseGlb(bytes), debugName: 'glb_parse');

  void _pushCamera() {
    final id = _textureId;
    if (id == null) return;
    if (_cameraBusy) {
      _cameraDirty = true;
      return;
    }
    _cameraBusy = true;
    GlbChannel.setCamera(id, yaw: _yaw, pitch: _pitch, distance: _distance)
        .catchError((Object _) {})
        .whenComplete(() {
      if (id != _textureId) return;
      _cameraBusy = false;
      if (_cameraDirty) {
        _cameraDirty = false;
        _pushCamera();
      }
    });
  }

  void _pushStyle() {
    final id = _textureId;
    if (id == null) return;
    GlbChannel.setStyle(id, widget.style).catchError((Object _) {});
  }

  void _onScaleStart(ScaleStartDetails details) {
    _scaleStartDistance = _distance;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      if (details.scale <= 0) return;
      _distance = (_scaleStartDistance / details.scale)
          .clamp(GlbView.minDistance, GlbView.maxDistance);
    } else {
      const degreesPerPixel = 0.4;
      _yaw += details.focalPointDelta.dx * degreesPerPixel;
      _pitch = (_pitch + details.focalPointDelta.dy * degreesPerPixel)
          .clamp(GlbView.minPitch, GlbView.maxPitch);
    }
    _pushCamera();
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    final error = _error;
    Widget child = Stack(
      fit: StackFit.expand,
      children: [
        if (id != null && error == null) Texture(textureId: id),
        if (error != null)
          widget.errorBuilder?.call(context, error) ?? _DefaultError(error)
        else if (!_ready)
          widget.placeholder ??
              const Center(
                child: SizedBox.square(
                  dimension: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
      ],
    );
    if (widget.interactive && error == null) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: child,
      );
    }
    return SizedBox(width: widget.width, height: widget.height, child: child);
  }
}

class _DefaultError extends StatelessWidget {
  const _DefaultError(this.error);

  final Object error;

  @override
  Widget build(BuildContext context) {
    final message = switch (error) {
      GlbFormatException(:final message) => message,
      PlatformException(:final message, :final code) => message ?? code,
      _ => error.toString(),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
