/// Native GLB (binary glTF 2.0) viewer.
///
/// The GLB is parsed in Dart (in a background isolate) into flat, world-space
/// triangle data and rendered natively: OpenGL ES 2.0 on Android, Metal on
/// iOS. Frames reach Flutter through a [Texture] widget.
library;

export 'src/glb_parser.dart'
    show GlbFormatException, GlbModel, GlbPrimitive, kFloatsPerVertex, parseGlb;
export 'src/glb_view.dart' show GlbErrorBuilder, GlbView;
