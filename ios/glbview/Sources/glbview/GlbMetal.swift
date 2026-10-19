import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

/// GPU-ready data for one draw call, as produced by the Dart parser.
struct PrimitiveData {
  /// Interleaved position(3) normal(3) uv(2) tangent(4) float32, unique vertices.
  let vertices: Data
  /// Triangle list into `vertices`, uint32.
  let indices: Data
  let baseColor: [Float]
  /// Encoded PNG/JPEG bytes.
  let texture: Data?
  let metallic: Float
  let roughness: Float
  let normalTexture: Data?
  let normalScale: Float
  let metallicRoughnessTexture: Data?
  let clearcoat: Float
}

/// Per-view replacement of one primitive's material inputs.
struct OverrideData {
  let index: Int
  let texture: Data?
  let normalTexture: Data?
  let metallicRoughnessTexture: Data?
  let baseColor: [Float]?
}

/// Shading parameters from `setStyle`. Colors are sRGB components 0..1.
struct GlbStyle {
  var glossy = true
  var gloss: Float = 1
  var glossOverridesMaterial = true
  var gradientTop = SIMD3<Float>(0.937, 0.953, 1)
  var gradientBottom = SIMD3<Float>(0.227, 0.247, 0.333)
  var gradientMix: Float = 0
  var sparkle: Float = 0.5
  var specularColor = SIMD3<Float>(1, 1, 1)

  /// Sparkle drifts and twinkles over time, so it needs continuous frames.
  var animated: Bool { glossy && gloss > 0 && sparkle > 0 }
}

enum GlbRendererError: Error, CustomStringConvertible {
  case noMetal
  case setup(String)

  var description: String {
    switch self {
    case .noMetal: return "Metal is not available on this device"
    case .setup(let message): return message
    }
  }
}

final class GpuMesh {
  let vertexBuffer: MTLBuffer
  let indexBuffer: MTLBuffer
  let indexCount: Int
  let baseColor: SIMD4<Float>
  let texture: MTLTexture?
  let metallic: Float
  let roughness: Float
  let normalTexture: MTLTexture?
  let normalScale: Float
  let mrTexture: MTLTexture?
  let clearcoat: Float

  init(
    vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, indexCount: Int, baseColor: SIMD4<Float>,
    texture: MTLTexture?, metallic: Float, roughness: Float, normalTexture: MTLTexture?,
    normalScale: Float, mrTexture: MTLTexture?, clearcoat: Float
  ) {
    self.vertexBuffer = vertexBuffer
    self.indexBuffer = indexBuffer
    self.indexCount = indexCount
    self.baseColor = baseColor
    self.texture = texture
    self.metallic = metallic
    self.roughness = roughness
    self.normalTexture = normalTexture
    self.normalScale = normalScale
    self.mrTexture = mrTexture
    self.clearcoat = clearcoat
  }
}

/// A model in the GPU store. Metal frees the buffers and textures when the
/// last reference (store or view) goes away.
final class GpuModel {
  let meshes: [GpuMesh]
  init(meshes: [GpuMesh]) { self.meshes = meshes }
}

struct GpuOverride {
  let texture: MTLTexture?
  let normalTexture: MTLTexture?
  let mrTexture: MTLTexture?
  let baseColor: SIMD4<Float>?
}

/// Metal state shared by every GlbView: the device, one compiled pipeline and
/// the GPU model store. The pipeline compiles in the background as soon as
/// the plugin registers, so the first view doesn't pay for it.
final class GlbMetal {
  static let floatsPerVertex = 12
  static let strideBytes = floatsPerVertex * MemoryLayout<Float>.size
  static let sampleCount = 4

  let device: MTLDevice
  let queue: MTLCommandQueue
  let depthState: MTLDepthStencilState
  let sampler: MTLSamplerState
  let whiteTexture: MTLTexture
  private let loader: MTKTextureLoader

  /// Nil until the background compile finishes (main thread).
  private(set) var pipeline: MTLRenderPipelineState?
  private var onPipeline: [() -> Void] = []

  /// Cached models by key (main thread).
  private var models: [String: GpuModel] = [:]

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw GlbRendererError.noMetal
    }
    self.device = device
    self.queue = queue
    loader = MTKTextureLoader(device: device)

    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .lessEqual
    depthDescriptor.isDepthWriteEnabled = true
    guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
      throw GlbRendererError.setup("Depth state creation failed")
    }
    self.depthState = depthState

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.mipFilter = .linear
    samplerDescriptor.sAddressMode = .repeat
    samplerDescriptor.tAddressMode = .repeat
    guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
      throw GlbRendererError.setup("Sampler creation failed")
    }
    self.sampler = sampler

    let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
    guard let white = device.makeTexture(descriptor: whiteDescriptor) else {
      throw GlbRendererError.setup("Texture creation failed")
    }
    var whitePixel: [UInt8] = [255, 255, 255, 255]
    white.replace(
      region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &whitePixel, bytesPerRow: 4)
    whiteTexture = white

    let start = CACurrentMediaTime()
    DispatchQueue.global(qos: .userInitiated).async { [device] in
      let result = Result { try GlbMetal.makePipeline(device: device) }
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        switch result {
        case .success(let pipeline):
          self.pipeline = pipeline
          NSLog("GlbView: Metal pipeline ready (%.1f ms)", (CACurrentMediaTime() - start) * 1000)
        case .failure(let error):
          NSLog("GlbView: Metal pipeline failed: %@", "\(error)")
        }
        let waiting = self.onPipeline
        self.onPipeline = []
        waiting.forEach { $0() }
      }
    }
  }

  /// Runs [block] on the main thread once the pipeline compile has finished.
  func whenPipelineReady(_ block: @escaping () -> Void) {
    if pipeline != nil { block() } else { onPipeline.append(block) }
  }

  private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
    let library: MTLLibrary
    do {
      library = try device.makeLibrary(source: GlbShaders.metalSource, options: nil)
    } catch {
      throw GlbRendererError.setup("Shader compile failed: \(error)")
    }
    let vertexDescriptor = MTLVertexDescriptor()
    let formats: [(MTLVertexFormat, Int)] = [(.float3, 0), (.float3, 12), (.float2, 24), (.float4, 32)]
    for (i, (format, offset)) in formats.enumerated() {
      vertexDescriptor.attributes[i].format = format
      vertexDescriptor.attributes[i].offset = offset
      vertexDescriptor.attributes[i].bufferIndex = 0
    }
    vertexDescriptor.layouts[0].stride = strideBytes
    vertexDescriptor.layouts[0].stepFunction = .perVertex

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "glb_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "glb_fragment")
    descriptor.vertexDescriptor = vertexDescriptor
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.depthAttachmentPixelFormat = .depth32Float
    descriptor.rasterSampleCount = sampleCount
    do {
      return try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      throw GlbRendererError.setup("Pipeline creation failed: \(error)")
    }
  }

  // MARK: - Model store (main thread)

  func model(_ key: String) -> GpuModel? { models[key] }

  func evictModel(_ key: String) {
    models.removeValue(forKey: key)
  }

  /// Uploads a model under [key]. Buffers are built and textures decoded
  /// concurrently off the main thread; [completion] runs on the main thread.
  func cacheModel(
    _ key: String, _ primitives: [PrimitiveData], logTimings: Bool,
    completion: @escaping (String?) -> Void
  ) {
    let start = CACurrentMediaTime()
    let images = primitives.flatMap { [$0.texture, $0.normalTexture, $0.metallicRoughnessTexture] }
    loadTextures(images) { [weak self] textures in
      guard let self = self else { return }
      DispatchQueue.global(qos: .userInitiated).async {
        var meshes: [GpuMesh] = []
        var failure: String?
        for (i, p) in primitives.enumerated() {
          // makeBuffer copies the raw bytes, so Data's alignment doesn't matter.
          let vertexBuffer = p.vertices.withUnsafeBytes { raw in
            raw.baseAddress.flatMap {
              self.device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared)
            }
          }
          let indexBuffer = p.indices.withUnsafeBytes { raw in
            raw.baseAddress.flatMap {
              self.device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared)
            }
          }
          guard let vb = vertexBuffer, let ib = indexBuffer else {
            failure = "Could not allocate GPU buffers"
            break
          }
          let c = p.baseColor
          meshes.append(
            GpuMesh(
              vertexBuffer: vb, indexBuffer: ib,
              indexCount: p.indices.count / MemoryLayout<UInt32>.size,
              baseColor: c.count >= 4 ? SIMD4<Float>(c[0], c[1], c[2], c[3]) : SIMD4<Float>(1, 1, 1, 1),
              texture: textures[i * 3], metallic: p.metallic, roughness: p.roughness,
              normalTexture: textures[i * 3 + 1], normalScale: p.normalScale,
              mrTexture: textures[i * 3 + 2], clearcoat: p.clearcoat))
        }
        DispatchQueue.main.async {
          if let failure = failure {
            completion(failure)
            return
          }
          self.models[key] = GpuModel(meshes: meshes)
          if logTimings {
            NSLog("GlbView timing [%@]: GPU upload %.1f ms", key, (CACurrentMediaTime() - start) * 1000)
          }
          completion(nil)
        }
      }
    }
  }

  /// Decodes [images] concurrently; [completion] gets textures in the same
  /// order (nil where absent or undecodable) on an arbitrary queue.
  func loadTextures(_ images: [Data?], completion: @escaping ([MTLTexture?]) -> Void) {
    var results = [MTLTexture?](repeating: nil, count: images.count)
    let lock = NSLock()
    let group = DispatchGroup()
    // Raw (non-sRGB) loads: the shader linearizes base color itself, and
    // normal / metal-rough maps are data.
    let options: [MTKTextureLoader.Option: Any] = [
      .SRGB: false,
      .generateMipmaps: true,
      .origin: MTKTextureLoader.Origin.topLeft,
      .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
      .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
    ]
    for (i, data) in images.enumerated() {
      guard let data = data else { continue }
      group.enter()
      loader.newTexture(data: data, options: options) { texture, error in
        if texture == nil { NSLog("GlbView: could not decode texture image: %@", "\(String(describing: error))") }
        lock.lock()
        results[i] = texture
        lock.unlock()
        group.leave()
      }
    }
    group.notify(queue: .global(qos: .userInitiated)) { completion(results) }
  }
}
