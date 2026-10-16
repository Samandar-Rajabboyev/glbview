import 'dart:ui' show Color;

/// Shading parameters sent to the native renderers with `setStyle`.
class GlbStyle {
  const GlbStyle({
    required this.glossy,
    required this.gloss,
    required this.glossOverridesMaterial,
    required this.gradientTop,
    required this.gradientBottom,
    required this.gradientMix,
    required this.sparkle,
    required this.specularColor,
  });

  /// Neutral studio environment used when no gradient colors are given.
  static const Color defaultGradientTop = Color(0xFFEFF3FF);
  static const Color defaultGradientBottom = Color(0xFF3A3F55);

  final bool glossy;
  final double gloss;
  final bool glossOverridesMaterial;
  final Color gradientTop;
  final Color gradientBottom;
  final double gradientMix;
  final double sparkle;
  final Color specularColor;

  Map<String, Object> toMap() => {
        'glossy': glossy,
        'gloss': gloss.clamp(0.0, 1.0),
        'glossOverridesMaterial': glossOverridesMaterial,
        'gradientTop': gradientTop.toARGB32(),
        'gradientBottom': gradientBottom.toARGB32(),
        'gradientMix': gradientMix.clamp(0.0, 1.0),
        'sparkle': sparkle.clamp(0.0, 1.0),
        'specularColor': specularColor.toARGB32(),
      };

  @override
  bool operator ==(Object other) =>
      other is GlbStyle &&
      other.glossy == glossy &&
      other.gloss == gloss &&
      other.glossOverridesMaterial == glossOverridesMaterial &&
      other.gradientTop == gradientTop &&
      other.gradientBottom == gradientBottom &&
      other.gradientMix == gradientMix &&
      other.sparkle == sparkle &&
      other.specularColor == specularColor;

  @override
  int get hashCode => Object.hash(glossy, gloss, glossOverridesMaterial,
      gradientTop, gradientBottom, gradientMix, sparkle, specularColor);
}
