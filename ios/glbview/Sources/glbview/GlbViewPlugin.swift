import Flutter
import UIKit

/// Bridges the method channel to the shared [GlbMetal] state and per-view
/// [GlbRenderer]s.
public class GlbViewPlugin: NSObject, FlutterPlugin {
  private let textures: FlutterTextureRegistry
  /// Created at registration so the pipeline compiles before any view.
  private let metal: GlbMetal?
  private let metalError: String?
  private var renderers: [Int64: GlbRenderer] = [:]

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    do {
      metal = try GlbMetal()
      metalError = nil
    } catch {
      metal = nil
      metalError = "\(error)"
    }
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
    guard let metal = metal else {
      result(FlutterError(code: "no_metal", message: metalError, details: nil))
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      do {
        let renderer = try GlbRenderer(
          metal: metal,
          width: max(1, (args["width"] as? NSNumber)?.intValue ?? 1),
          height: max(1, (args["height"] as? NSNumber)?.intValue ?? 1),
          autoRotate: (args["autoRotate"] as? NSNumber)?.doubleValue ?? 0,
          logTimings: (args["debugTimings"] as? NSNumber)?.boolValue ?? false,
          registry: textures)
        let id = textures.register(renderer)
        renderer.start(textureId: id)
        renderers[id] = renderer
        result(NSNumber(value: id))
      } catch {
        result(FlutterError(code: "create_failed", message: "\(error)", details: nil))
      }

    case "cacheModel":
      guard let key = args["key"] as? String, let raw = args["primitives"] as? [[String: Any]] else {
        result(FlutterError(code: "bad_args", message: "Missing key or primitives", details: nil))
        return
      }
      var primitives: [PrimitiveData] = []
      for item in raw {
        guard let vertices = item["vertices"] as? FlutterStandardTypedData,
          let indices = item["indices"] as? FlutterStandardTypedData
        else { continue }
        let color = (item["baseColor"] as? FlutterStandardTypedData).map(Self.floats)
        primitives.append(
          PrimitiveData(
            vertices: vertices.data,
            indices: indices.data,
            baseColor: color?.count == 4 ? color! : [1, 1, 1, 1],
            texture: Self.bytes(item["texture"]),
            metallic: (item["metallic"] as? NSNumber)?.floatValue ?? 0,
            roughness: (item["roughness"] as? NSNumber)?.floatValue ?? 0.5,
            normalTexture: Self.bytes(item["normalTexture"]),
            normalScale: (item["normalScale"] as? NSNumber)?.floatValue ?? 1,
            metallicRoughnessTexture: Self.bytes(item["metallicRoughnessTexture"]),
            clearcoat: (item["clearcoat"] as? NSNumber)?.floatValue ?? 0))
      }
      metal.cacheModel(
        key, primitives, logTimings: (args["debugTimings"] as? NSNumber)?.boolValue ?? false
      ) { error in
        result(error.map { FlutterError(code: "load_failed", message: $0, details: nil) })
      }

    case "evictModel":
      if let key = args["key"] as? String { metal.evictModel(key) }
      result(nil)

    case "setModel":
      guard let renderer = renderer(args, result) else { return }
      let key = args["key"] as? String ?? ""
      if renderer.setModel(key) {
        result(nil)
      } else {
        result(FlutterError(code: "not_cached", message: "Model '\(key)' is not cached", details: nil))
      }

    case "setOverrides":
      guard let renderer = renderer(args, result) else { return }
      let raw = args["overrides"] as? [[String: Any]] ?? []
      let overrides = raw.compactMap { item -> OverrideData? in
        guard let index = (item["index"] as? NSNumber)?.intValue else { return nil }
        return OverrideData(
          index: index,
          texture: Self.bytes(item["texture"]),
          normalTexture: Self.bytes(item["normalTexture"]),
          metallicRoughnessTexture: Self.bytes(item["metallicRoughnessTexture"]),
          baseColor: (item["baseColor"] as? FlutterStandardTypedData).map(Self.floats))
      }
      renderer.setOverrides(overrides) { result(nil) }

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

  private static func bytes(_ value: Any?) -> Data? {
    (value as? FlutterStandardTypedData)?.data
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
