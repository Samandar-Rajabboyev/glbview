import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glb_cache.dart';
import 'glb_channel.dart';
import 'glb_material_override.dart';
import 'glb_parser.dart';
import 'glb_style.dart';

/// Touch gestures a [GlbView] responds to. Combine them in a set, e.g.
/// `gestures: {GlbGesture.rotate, GlbGesture.zoom}`.
enum GlbGesture {
  /// Horizontal drag turns the model around its vertical axis (yaw).
  rotate,

  /// Vertical drag tilts the model (pitch, clamped to ±85°).
  tilt,

  /// Pinch zooms (camera distance 1.6..10).
  zoom;

  /// Every gesture (the default).
  static const Set<GlbGesture> all = {rotate, tilt, zoom};

  /// Drag in any direction to orbit, no zoom.
  static const Set<GlbGesture> orbit = {rotate, tilt};

  /// Not interactive.
  static const Set<GlbGesture> none = {};
}

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
    this.gestures = GlbGesture.all,
    @Deprecated('Use gestures; interactive: false equals GlbGesture.none')
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
        bytes = null,
        cacheKey = null;

  /// Shows a GLB held in memory.
  const GlbView.memory(
    Uint8List this.bytes, {
    super.key,
    this.width = 300,
    this.height = 300,
    this.autoRotate = true,
    this.autoRotateDegreesPerSecond = 20,
    this.gestures = GlbGesture.all,
    @Deprecated('Use gestures; interactive: false equals GlbGesture.none')
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
    this.cacheKey,
  })  : assetName = null,
        package = null,
        bundle = null;

  final String? assetName;
  final String? package;
  final AssetBundle? bundle;
  final Uint8List? bytes;

  /// Identifies [bytes] in the model cache across different buffer objects
  /// (e.g. a model downloaded again). Without it the cache entry is tied to
  /// the buffer object itself. See [precacheMemory].
  final String? cacheKey;

  /// Logical size of the view.
  final double width;
  final double height;

  final bool autoRotate;
  final double autoRotateDegreesPerSecond;

  /// Which touch gestures move the camera; any combination of
  /// [GlbGesture]s. Gestures not in the set pass through to ancestors, so
  /// e.g. `{GlbGesture.rotate}` (horizontal drags only) keeps a vertical
  /// scroll view scrollable over the model. Including [GlbGesture.zoom]
  /// needs a scale recognizer, which also claims vertical drags.
  final Set<GlbGesture> gestures;

  /// Whether the view reacts to touch at all.
  @Deprecated('Use gestures; interactive: false equals GlbGesture.none')
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

  /// Logs per-phase load timings (read, parse, GPU upload, native view
  /// creation, first frame) to the console. For profiling; off by default.
  static bool get debugTimings => GlbCache.debugTimings;
  static set debugTimings(bool value) => GlbCache.debugTimings = value;

  /// Parses the asset and uploads it to the GPU ahead of time, so a
  /// [GlbView.asset] showing it later appears without a loading phase. Call
  /// it before navigating to the screen, e.g. in `initState` of the
  /// previous one. Completes when the model is ready to draw.
  static Future<void> precacheAsset(
    String name, {
    String? package,
    AssetBundle? bundle,
  }) {
    final key = GlbCache.assetKey(name, package);
    return GlbCache.load(
      key,
      () => GlbCache.readAsset(bundle ?? rootBundle, key.substring(6)),
    );
  }

  /// Like [precacheAsset] for a model held in memory. Pass the same [bytes]
  /// object (or the same [cacheKey]) to [GlbView.memory] later.
  static Future<void> precacheMemory(Uint8List bytes, {String? cacheKey}) {
    return GlbCache.load(
      GlbCache.memoryKey(bytes, cacheKey),
      () async => bytes,
    );
  }

  /// Removes a precached or previously shown asset from the cache. Models a
  /// mounted view is showing stay until that view is gone.
  static void evictAsset(String name, {String? package}) =>
      GlbCache.evict(GlbCache.assetKey(name, package));

  /// Removes a memory model from the cache (see [precacheMemory]).
  static void evictMemory(Uint8List bytes, {String? cacheKey}) =>
      GlbCache.evict(GlbCache.memoryKey(bytes, cacheKey));

  /// Evicts every cached model that no mounted view is showing.
  static void clearCache() => GlbCache.clear();

  /// How many models no view is showing stay cached on the GPU (least
  /// recently used are evicted first). Models in use don't count.
  static int get maxUnusedModels => GlbCache.maxUnusedModels;
  static set maxUnusedModels(int value) => GlbCache.maxUnusedModels = value;

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

  /// The model was already cached when loading started: skip the
  /// placeholder, which would only flash for a frame or two.
  bool _instant = false;

  /// Bumped whenever an in-flight load becomes obsolete.
  int _generation = 0;
  double? _devicePixelRatio;

  /// Cache key of the model this view holds a reference on.
  String? _heldKey;
  GlbModelInfo? _info;

  /// Overrides last sent to the native view, and whether a send is running.
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

  String get _key => widget.bytes != null
      ? GlbCache.memoryKey(widget.bytes!, widget.cacheKey)
      : GlbCache.assetKey(widget.assetName!, widget.package);

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
        old.cacheKey != widget.cacheKey ||
        !identical(old.bytes, widget.bytes);
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
    _releaseModel();
    super.dispose();
  }

  void _releaseTexture() {
    final id = _textureId;
    _textureId = null;
    if (id != null) {
      GlbChannel.dispose(id).catchError((Object _) {});
    }
  }

  void _releaseModel() {
    final key = _heldKey;
    _heldKey = null;
    _info = null;
    if (key != null) GlbCache.release(key);
  }

  /// Throws away the current texture and builds a new one. Called from
  /// lifecycle methods, so state is mutated directly (a build follows).
  void _recreate() {
    final gen = ++_generation;
    _releaseTexture();
    _releaseModel();
    _ready = false;
    _error = null;
    _cameraBusy = false;
    _cameraDirty = false;
    _sentOverrides = null;
    _overridesBusy = false;
    final key = _key;
    _instant = GlbCache.isReady(key);
    // Hold the model from the start so the cache can't evict it mid-load.
    _heldKey = key;
    final infoFuture = GlbCache.load(key, _bytesLoader());
    GlbCache.acquire(key);
    _load(gen, key, infoFuture);
  }

  /// Captures what reading the source needs now, while `context` is valid.
  Future<Uint8List> Function() _bytesLoader() {
    final bytes = widget.bytes;
    if (bytes != null) return () async => bytes;
    final bundle = widget.bundle ?? DefaultAssetBundle.of(context);
    final assetKey = GlbCache.assetKey(widget.assetName!, widget.package);
    return () => GlbCache.readAsset(bundle, assetKey.substring(6));
  }

  Future<void> _load(
      int gen, String key, Future<GlbModelInfo> infoFuture) async {
    final dpr = _devicePixelRatio ?? 1;
    // Errors are handled when awaited below; don't report them as unhandled
    // while the native view is still being created.
    infoFuture.ignore();
    final sw = Stopwatch()..start();
    try {
      final id = await GlbChannel.create(
        width: (widget.width * dpr).round().clamp(1, 4096),
        height: (widget.height * dpr).round().clamp(1, 4096),
        autoRotate: widget.autoRotate ? widget.autoRotateDegreesPerSecond : 0,
        debugTimings: GlbView.debugTimings,
      );
      if (gen != _generation || !mounted) {
        GlbChannel.dispose(id).catchError((Object _) {});
        return;
      }
      setState(() => _textureId = id);
      final created = sw.elapsedMilliseconds;

      final info = await infoFuture;
      if (gen != _generation || !mounted) return;
      _info = info;
      final cached = sw.elapsedMilliseconds;
      await GlbChannel.setCamera(id,
          yaw: _yaw, pitch: _pitch, distance: _distance);
      await GlbChannel.setStyle(id, widget.style);
      await _sendOverrides(id, info);
      await GlbChannel.setModel(id, key);
      if (gen != _generation || !mounted) return;
      if (GlbView.debugTimings) {
        debugPrint('GlbView timing [$key]: view created ${created}ms, '
            'model ready ${cached}ms, attached ${sw.elapsedMilliseconds}ms '
            '(${_instant ? 'cached' : 'cold'})');
      }
      setState(() => _ready = true);
      // Overrides may have changed while loading.
      _syncOverrides();
    } catch (e, st) {
      if (gen != _generation || !mounted) return;
      debugPrint('GlbView: failed to load model: $e\n$st');
      setState(() => _error = e);
    }
  }

  /// Sends the current overrides, resolved from material names to the
  /// model's primitive indices.
  Future<void> _sendOverrides(int id, GlbModelInfo info) {
    final overrides = widget.materialOverrides;
    _sentOverrides = overrides;
    final list = <Map<String, Object?>>[];
    if (overrides != null) {
      assert(() {
        final unknown =
            overrides.keys.where((k) => !info.materialNames.contains(k));
        if (unknown.isNotEmpty) {
          debugPrint('GlbView: no material named ${unknown.join(', ')}; '
              'this model has ${info.materialNames.whereType<String>().join(', ')}');
        }
        return true;
      }());
      for (var i = 0; i < info.materialNames.length; i++) {
        final o = overrides[info.materialNames[i]];
        if (o == null) continue;
        list.add({
          'index': i,
          'texture': o.baseColorTexture,
          'normalTexture': o.normalTexture,
          'metallicRoughnessTexture': o.metallicRoughnessTexture,
          'baseColor': o.baseColor == null ? null : linearFactor(o.baseColor!),
        });
      }
    }
    return GlbChannel.setOverrides(id, list);
  }

  /// Re-sends overrides when they differ from the last send. Serialized,
  /// and loops until the latest overrides are applied.
  Future<void> _syncOverrides() async {
    final id = _textureId;
    final info = _info;
    if (!_ready ||
        _overridesBusy ||
        id == null ||
        info == null ||
        mapEquals(_sentOverrides, widget.materialOverrides)) {
      return;
    }
    final gen = _generation;
    _overridesBusy = true;
    try {
      await _sendOverrides(id, info);
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

  void _pushStyle() {
    final id = _textureId;
    if (id == null) return;
    GlbChannel.setStyle(id, widget.style).catchError((Object _) {});
  }

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

  Set<GlbGesture> get _gestures =>
      // ignore: deprecated_member_use_from_same_package
      widget.interactive ? widget.gestures : GlbGesture.none;

  static const double _degreesPerPixel = 0.4;

  /// Fingers currently down on the view, with their last local position.
  final Map<int, Offset> _pointers = {};

  /// True while one of the recognizers has won a drag/scale gesture.
  ///
  /// Recognizers only decide *when* the view handles a gesture (and compete
  /// with scroll views for it). The movement itself comes from each pointer's
  /// own move events: drag recognizers' deltas can't be trusted here. On iOS
  /// the pan recognizer reported a delta relative to a previous gesture on
  /// the first move of a new drag (snapping the model back), and drag
  /// recognizers fold several fingers into one delta. Event deltas aren't
  /// used either: on iOS the first move of a new touch carried a delta from
  /// the previous touch's last position. Movement is the difference between
  /// a pointer's own positions.
  bool _dragging = false;

  void _onPointerDown(PointerDownEvent e) =>
      _pointers[e.pointer] = e.localPosition;

  void _onPointerUp(PointerEvent e) => _pointers.remove(e.pointer);

  /// Widget listeners see a move before the recognizers do (those are fed by
  /// the gesture binding afterwards), so the move that makes a recognizer
  /// win is not applied: the touch slop is skipped instead of being caught
  /// up in one jump.
  void _onPointerMove(PointerMoveEvent e) {
    final last = _pointers[e.pointer];
    _pointers[e.pointer] = e.localPosition;
    if (last == null || !_dragging || _pointers.length != 1) return;
    _drag(e.localPosition - last);
  }

  void _dragStart() => _dragging = true;

  void _dragEnd() => _dragging = false;

  /// Applies a one-finger drag, honoring which of rotate/tilt are enabled.
  void _drag(Offset delta) {
    final gestures = _gestures;
    if (gestures.contains(GlbGesture.rotate)) {
      _yaw += delta.dx * _degreesPerPixel;
    }
    if (gestures.contains(GlbGesture.tilt)) {
      _pitch = (_pitch + delta.dy * _degreesPerPixel)
          .clamp(GlbView.minPitch, GlbView.maxPitch);
    }
    _pushCamera();
  }

  void _onScaleStart(ScaleStartDetails details) {
    _scaleStartDistance = _distance;
    _dragStart();
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      // Only reached when zoom is enabled (the scale recognizer is used).
      if (details.scale <= 0) return;
      _distance = (_scaleStartDistance / details.scale)
          .clamp(GlbView.minDistance, GlbView.maxDistance);
      _pushCamera();
    }
    // One-finger rotate/tilt is applied from pointer moves.
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
        else if (!_ready && !_instant)
          widget.placeholder ??
              const Center(
                child: SizedBox.square(
                  dimension: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
      ],
    );
    final gestures = _gestures;
    if (gestures.isNotEmpty && error == null) {
      // The narrowest recognizer that covers the enabled gestures, so the
      // rest stay available to ancestors (e.g. a vertical scroll view).
      final rotate = gestures.contains(GlbGesture.rotate);
      final tilt = gestures.contains(GlbGesture.tilt);
      child = gestures.contains(GlbGesture.zoom)
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: (_) => _dragEnd(),
              child: child,
            )
          : rotate && tilt
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => _dragStart(),
                  onPanEnd: (_) => _dragEnd(),
                  onPanCancel: _dragEnd,
                  child: child,
                )
              : rotate
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _dragStart(),
                      onHorizontalDragEnd: (_) => _dragEnd(),
                      onHorizontalDragCancel: _dragEnd,
                      child: child,
                    )
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: (_) => _dragStart(),
                      onVerticalDragEnd: (_) => _dragEnd(),
                      onVerticalDragCancel: _dragEnd,
                      child: child,
                    );
      child = Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
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
