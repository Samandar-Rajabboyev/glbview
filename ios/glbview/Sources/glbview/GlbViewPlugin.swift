import Flutter
import UIKit

/// Hosts native GLB renderers, one per Flutter texture.
public class GlbViewPlugin: NSObject, FlutterPlugin {
  private let textures: FlutterTextureRegistry
  private var renderers: [Int64: GlbRenderer] = [:]

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.samandar/glbview", binaryMessenger: registrar.messenger())
    let instance = GlbViewPlugin(textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    renderers.values.forEach { $0.dispose() }
    renderers.removeAll()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      let width = max(1, (args["width"] as? NSNumber)?.intValue ?? 1)
      let height = max(1, (args["height"] as? NSNumber)?.intValue ?? 1)
      let autoRotate = (args["autoRotate"] as? NSNumber)?.doubleValue ?? 0
      do {
        let renderer = try GlbRenderer(
          width: width, height: height, autoRotate: autoRotate, registry: textures)
        let id = textures.register(renderer)
        renderer.start(textureId: id)
        renderers[id] = renderer
        result(NSNumber(value: id))
      } catch {
        result(FlutterError(code: "create_failed", message: "\(error)", details: nil))
      }

    case "loadModel":
      guard let renderer = renderer(args, result) else { return }
      guard let raw = args["primitives"] as? [[String: Any]] else {
        result(FlutterError(code: "bad_args", message: "Missing primitives", details: nil))
        return
      }
      var primitives: [PrimitiveData] = []
      for item in raw {
        guard let vertices = item["vertices"] as? FlutterStandardTypedData else { continue }
        let color = (item["baseColor"] as? FlutterStandardTypedData).map(Self.floats)
        primitives.append(
          PrimitiveData(
            vertices: vertices.data,
            baseColor: color?.count == 4 ? color! : [1, 1, 1, 1],
            texture: (item["texture"] as? FlutterStandardTypedData)?.data,
            metallic: (item["metallic"] as? NSNumber)?.floatValue ?? 0,
            roughness: (item["roughness"] as? NSNumber)?.floatValue ?? 0.5,
            normalTexture: (item["normalTexture"] as? FlutterStandardTypedData)?.data,
            normalScale: (item["normalScale"] as? NSNumber)?.floatValue ?? 1,
            metallicRoughnessTexture: (item["metallicRoughnessTexture"] as? FlutterStandardTypedData)?
              .data,
            clearcoat: (item["clearcoat"] as? NSNumber)?.floatValue ?? 0))
      }
      renderer.loadModel(primitives) { error in
        if let error = error {
          result(FlutterError(code: "load_failed", message: error, details: nil))
        } else {
          result(nil)
        }
      }

    case "setCamera":
      guard let renderer = renderer(args, result) else { return }
      renderer.setCamera(
        yaw: (args["yaw"] as? NSNumber)?.floatValue ?? 0,
        pitch: (args["pitch"] as? NSNumber)?.floatValue ?? 0,
        distance: (args["distance"] as? NSNumber)?.floatValue ?? 3.2)
      result(nil)

    case "setStyle":
      guard let renderer = renderer(args, result) else { return }
      var style = GlbStyle()
      style.glossy = (args["glossy"] as? NSNumber)?.boolValue ?? true
      style.gloss = (args["gloss"] as? NSNumber)?.floatValue ?? 1
      style.glossOverridesMaterial = (args["glossOverridesMaterial"] as? NSNumber)?.boolValue ?? true
      style.gradientTop = Self.rgb(args["gradientTop"]) ?? style.gradientTop
      style.gradientBottom = Self.rgb(args["gradientBottom"]) ?? style.gradientBottom
      style.gradientMix = (args["gradientMix"] as? NSNumber)?.floatValue ?? 0
      style.sparkle = (args["sparkle"] as? NSNumber)?.floatValue ?? 0.5
      style.specularColor = Self.rgb(args["specularColor"]) ?? style.specularColor
      renderer.setStyle(style)
      result(nil)

    case "dispose":
      if let id = (args["id"] as? NSNumber)?.int64Value, let renderer = renderers.removeValue(forKey: id) {
        renderer.dispose()
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func renderer(_ args: [String: Any], _ result: FlutterResult) -> GlbRenderer? {
    guard let id = (args["id"] as? NSNumber)?.int64Value, let renderer = renderers[id] else {
      result(FlutterError(code: "no_texture", message: "Unknown texture id", details: nil))
      return nil
    }
    return renderer
  }

  /// ARGB int -> sRGB components 0..1 (alpha ignored).
  private static func rgb(_ value: Any?) -> SIMD3<Float>? {
    guard let argb = (value as? NSNumber)?.int64Value else { return nil }
    return SIMD3<Float>(
      Float((argb >> 16) & 0xFF) / 255, Float((argb >> 8) & 0xFF) / 255, Float(argb & 0xFF) / 255)
  }

  /// Copies a Float32List payload into a properly aligned Swift array.
  private static func floats(_ typed: FlutterStandardTypedData) -> [Float] {
    let data = typed.data
    let count = data.count / MemoryLayout<Float>.size
    var out = [Float](repeating: 0, count: count)
    out.withUnsafeMutableBytes { dst in
      _ = data.copyBytes(to: dst, count: count * MemoryLayout<Float>.size)
    }
    return out
  }
}
