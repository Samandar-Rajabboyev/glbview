import CoreVideo
import Flutter
import Metal
import MetalKit
import QuartzCore
import simd

/// GPU-ready data for one draw call, as produced by the Dart parser.
struct PrimitiveData {
  /// Interleaved position(3) normal(3) uv(2) tangent(4) float32, non-indexed
  /// triangles.
  let vertices: Data
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

// These match the structs of the same name in the Metal shader below.
private struct Uniforms {
  var mvp: simd_float4x4
  var model: simd_float4x4
  var cameraPos: SIMD4<Float>
  /// x, y: render target size in pixels; z: time in seconds.
  var resolutionTime: SIMD4<Float>
}

private struct MaterialUniforms {
  var baseColor: SIMD4<Float>
  /// metallic, roughness, hasTexture, hasNormalMap.
  var params: SIMD4<Float>
  /// normalScale, hasMetalRoughMap, clearcoat, unused.
  var params2: SIMD4<Float>
}

private struct StyleUniforms {
  var gradTop: SIMD4<Float>
  var gradBottom: SIMD4<Float>
  var specColor: SIMD4<Float>
  /// glossy, gloss, glossOverride, gradientMix.
  var params: SIMD4<Float>
  /// sparkle, unused...
  var params2: SIMD4<Float>
}

/// Avoids the retain cycle CADisplayLink would create with its target.
private final class WeakDisplayLinkProxy: NSObject {
  weak var target: GlbRenderer?

  init(_ target: GlbRenderer) {
    self.target = target
  }

  @objc func tick(_ link: CADisplayLink) {
    target?.tick(link)
  }
}

/// Renders a model with Metal into IOSurface-backed pixel buffers that
/// Flutter samples through `copyPixelBuffer`.
final class GlbRenderer: NSObject, FlutterTexture {
  private static let floatsPerVertex = 12
  private static let strideBytes = floatsPerVertex * MemoryLayout<Float>.size
  private static let bufferCount = 3
  private static let sampleCount = 4

  private struct RenderTarget {
    let pixelBuffer: CVPixelBuffer
    let cvTexture: CVMetalTexture  // keeps the Metal texture's backing alive
    let texture: MTLTexture
  }

  private struct Mesh {
    let buffer: MTLBuffer
    let vertexCount: Int
    var baseColor: SIMD4<Float>
    let texture: MTLTexture?
    let metallic: Float
    let roughness: Float
    let normalTexture: MTLTexture?
    let normalScale: Float
    let mrTexture: MTLTexture?
    let clearcoat: Float
  }

  private let width: Int
  private let height: Int
  private let autoRotate: Double
  private weak var registry: FlutterTextureRegistry?

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let depthState: MTLDepthStencilState
  private let sampler: MTLSamplerState
  private let whiteTexture: MTLTexture
  private let depthTexture: MTLTexture
  /// 4x MSAA color target, resolved into the current pixel buffer.
  private let msaaTexture: MTLTexture
  private let textureCache: CVMetalTextureCache
  private let targets: [RenderTarget]
  private let loadQueue = DispatchQueue(label: "dev.samandar.glbview.load")

  // Shared with the Flutter raster thread.
  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  // Main-thread state.
  private var textureId: Int64 = 0
  private var displayLink: CADisplayLink?
  private var meshes: [Mesh] = []
  private var nextTarget = 0
  private var inFlight = false
  private var dirty = true
  private var disposed = false
  private var loadGeneration = 0
  private var angle: Double = 0
  private var lastTimestamp: CFTimeInterval = 0
  private var yaw: Float = 0
  private var pitch: Float = 0
  private var distance: Float = 3.2
  private var style = GlbStyle()
  private var startTimestamp: CFTimeInterval = 0
  private let projection: simd_float4x4

  init(width: Int, height: Int, autoRotate: Double, registry: FlutterTextureRegistry) throws {
    self.width = width
    self.height = height
    self.autoRotate = autoRotate
    self.registry = registry

    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw GlbRendererError.noMetal
    }
    self.device = device
    self.queue = queue

    let library: MTLLibrary
    do {
      library = try device.makeLibrary(source: GlbRenderer.shaderSource, options: nil)
    } catch {
      throw GlbRendererError.setup("Shader compile failed: \(error)")
    }

    let vertexDescriptor = MTLVertexDescriptor()
    vertexDescriptor.attributes[0].format = .float3
    vertexDescriptor.attributes[0].offset = 0
    vertexDescriptor.attributes[0].bufferIndex = 0
    vertexDescriptor.attributes[1].format = .float3
    vertexDescriptor.attributes[1].offset = 12
    vertexDescriptor.attributes[1].bufferIndex = 0
    vertexDescriptor.attributes[2].format = .float2
    vertexDescriptor.attributes[2].offset = 24
    vertexDescriptor.attributes[2].bufferIndex = 0
    vertexDescriptor.attributes[3].format = .float4
    vertexDescriptor.attributes[3].offset = 32
    vertexDescriptor.attributes[3].bufferIndex = 0
    vertexDescriptor.layouts[0].stride = GlbRenderer.strideBytes
    vertexDescriptor.layouts[0].stepFunction = .perVertex

    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = library.makeFunction(name: "glb_vertex")
    pipelineDescriptor.fragmentFunction = library.makeFunction(name: "glb_fragment")
    pipelineDescriptor.vertexDescriptor = vertexDescriptor
    pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
    pipelineDescriptor.rasterSampleCount = GlbRenderer.sampleCount
    do {
      pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    } catch {
      throw GlbRendererError.setup("Pipeline creation failed: \(error)")
    }

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

    func multisampleDescriptor(_ format: MTLPixelFormat) -> MTLTextureDescriptor {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: width, height: height, mipmapped: false)
      d.textureType = .type2DMultisample
      d.sampleCount = GlbRenderer.sampleCount
      d.usage = .renderTarget
      d.storageMode = .private
      return d
    }
    guard let depth = device.makeTexture(descriptor: multisampleDescriptor(.depth32Float)),
      let msaa = device.makeTexture(descriptor: multisampleDescriptor(.bgra8Unorm))
    else {
      throw GlbRendererError.setup("MSAA texture creation failed")
    }
    depthTexture = depth
    msaaTexture = msaa

    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
      let textureCache = cache
    else {
      throw GlbRendererError.setup("CVMetalTextureCache creation failed")
    }
    self.textureCache = textureCache

    var targets: [RenderTarget] = []
    let attributes: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
    ]
    for _ in 0..<GlbRenderer.bufferCount {
      var pixelBuffer: CVPixelBuffer?
      guard
        CVPixelBufferCreate(
          kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
          attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
        let pb = pixelBuffer
      else {
        throw GlbRendererError.setup("CVPixelBuffer creation failed")
      }
      var cvTexture: CVMetalTexture?
      guard
        CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, textureCache, pb, nil, .bgra8Unorm, width, height, 0, &cvTexture)
          == kCVReturnSuccess,
        let cvTex = cvTexture, let texture = CVMetalTextureGetTexture(cvTex)
      else {
        throw GlbRendererError.setup("Metal texture from pixel buffer failed")
      }
      targets.append(RenderTarget(pixelBuffer: pb, cvTexture: cvTex, texture: texture))
    }
    self.targets = targets

    projection = GlbRenderer.perspective(
      fovyRadians: 40 * .pi / 180, aspect: Float(width) / Float(height), near: 0.1, far: 100)
    super.init()
  }

  // MARK: - Lifecycle (main thread)

  func start(textureId: Int64) {
    self.textureId = textureId
    let link = CADisplayLink(target: WeakDisplayLinkProxy(self), selector: #selector(WeakDisplayLinkProxy.tick(_:)))
    link.preferredFramesPerSecond = 60
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    displayLink?.invalidate()
    displayLink = nil
    registry?.unregisterTexture(textureId)
    meshes = []
    lock.lock()
    latest = nil
    lock.unlock()
  }

  func setStyle(_ style: GlbStyle) {
    self.style = style
    dirty = true
  }

  func setCamera(yaw: Float, pitch: Float, distance: Float) {
    self.yaw = yaw
    self.pitch = pitch
    self.distance = distance
    dirty = true
  }

  /// Uploads on a background queue; `completion` runs on the main thread with
  /// an error message or nil.
  func loadModel(_ primitives: [PrimitiveData], completion: @escaping (String?) -> Void) {
    loadGeneration += 1
    let generation = loadGeneration
    let device = self.device
    loadQueue.async { [weak self] in
      let loader = MTKTextureLoader(device: device)
      var built: [Mesh] = []
      var failure: String?
      for p in primitives {
        let usableBytes = p.vertices.count - p.vertices.count % GlbRenderer.strideBytes
        guard usableBytes > 0 else { continue }
        // makeBuffer copies the raw bytes, so Data's alignment doesn't matter.
        let buffer = p.vertices.withUnsafeBytes { raw -> MTLBuffer? in
          guard let base = raw.baseAddress else { return nil }
          return device.makeBuffer(bytes: base, length: usableBytes, options: .storageModeShared)
        }
        guard let vertexBuffer = buffer else {
          failure = "Could not allocate a vertex buffer"
          break
        }
        // Raw (non-sRGB) loads: the shader linearizes base color itself, and
        // normal / metal-rough maps are data.
        func load(_ bytes: Data?) -> MTLTexture? {
          guard let bytes = bytes else { return nil }
          let texture = try? loader.newTexture(
            data: bytes,
            options: [
              .SRGB: false,
              .generateMipmaps: true,
              .origin: MTKTextureLoader.Origin.topLeft,
              .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
              .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ])
          if texture == nil { NSLog("GlbView: could not decode texture image") }
          return texture
        }
        let texture = load(p.texture)
        let c = p.baseColor
        built.append(
          Mesh(
            buffer: vertexBuffer,
            vertexCount: usableBytes / GlbRenderer.strideBytes,
            baseColor: SIMD4<Float>(c[0], c[1], c[2], c[3]),
            texture: texture,
            metallic: p.metallic,
            roughness: p.roughness,
            normalTexture: load(p.normalTexture),
            normalScale: p.normalScale,
            mrTexture: load(p.metallicRoughnessTexture),
            clearcoat: p.clearcoat))
      }
      DispatchQueue.main.async {
        guard let self = self, !self.disposed, generation == self.loadGeneration else {
          completion(nil)
          return
        }
        if let failure = failure {
          completion(failure)
          return
        }
        self.meshes = built
        self.dirty = true
        completion(nil)
      }
    }
  }

  // MARK: - FlutterTexture (raster thread)

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  // MARK: - Rendering (main thread)

  fileprivate func tick(_ link: CADisplayLink) {
    let now = link.timestamp
    let dt = lastTimestamp == 0 ? 0 : now - lastTimestamp
    lastTimestamp = now
    if startTimestamp == 0 { startTimestamp = now }
    if autoRotate != 0 {
      angle = (angle + autoRotate * dt).truncatingRemainder(dividingBy: 360)
      dirty = true
    }
    if style.animated { dirty = true }
    // Skip while the previous frame is still on the GPU; `dirty` stays set.
    guard dirty, !inFlight, !disposed else { return }
    dirty = false
    render()
  }

  private func render() {
    let target = targets[nextTarget]
    nextTarget = (nextTarget + 1) % targets.count

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = msaaTexture
    pass.colorAttachments[0].resolveTexture = target.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .multisampleResolve
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    pass.depthAttachment.texture = depthTexture
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    pass.depthAttachment.clearDepth = 1

    guard let commandBuffer = queue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
    else { return }

    let model =
      GlbRenderer.rotationX(radians(pitch))
      * GlbRenderer.rotationY(radians(yaw + Float(angle)))
    let view = GlbRenderer.translation(0, 0, -distance)
    var uniforms = Uniforms(
      mvp: projection * view * model,
      model: model,
      cameraPos: SIMD4<Float>(0, 0, distance, 1),
      resolutionTime: SIMD4<Float>(
        Float(width), Float(height),
        // Wrapped so float precision in the shader stays good.
        Float((lastTimestamp - startTimestamp).truncatingRemainder(dividingBy: 1000)), 0))
    let st = style
    var styleUniforms = StyleUniforms(
      gradTop: SIMD4<Float>(st.gradientTop, 0),
      gradBottom: SIMD4<Float>(st.gradientBottom, 0),
      specColor: SIMD4<Float>(st.specularColor, 0),
      params: SIMD4<Float>(
        st.glossy ? 1 : 0, st.gloss, st.glossOverridesMaterial ? 1 : 0, st.gradientMix),
      params2: SIMD4<Float>(st.sparkle, 0, 0, 0))

    encoder.setRenderPipelineState(pipeline)
    encoder.setDepthStencilState(depthState)
    encoder.setCullMode(.none)
    encoder.setFrontFacing(.counterClockwise)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&styleUniforms, length: MemoryLayout<StyleUniforms>.stride, index: 3)
    encoder.setFragmentSamplerState(sampler, index: 0)
    for mesh in meshes {
      var material = MaterialUniforms(
        baseColor: mesh.baseColor,
        params: SIMD4<Float>(
          mesh.metallic, mesh.roughness, mesh.texture == nil ? 0 : 1, mesh.normalTexture == nil ? 0 : 1),
        params2: SIMD4<Float>(mesh.normalScale, mesh.mrTexture == nil ? 0 : 1, mesh.clearcoat, 0))
      encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
      encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: 2)
      encoder.setFragmentTexture(mesh.texture ?? whiteTexture, index: 0)
      encoder.setFragmentTexture(mesh.normalTexture ?? whiteTexture, index: 1)
      encoder.setFragmentTexture(mesh.mrTexture ?? whiteTexture, index: 2)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
    }
    encoder.endEncoding()

    let pixelBuffer = target.pixelBuffer
    commandBuffer.addCompletedHandler { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.inFlight = false
        guard !self.disposed else { return }
        self.lock.lock()
        self.latest = pixelBuffer
        self.lock.unlock()
        self.registry?.textureFrameAvailable(self.textureId)
      }
    }
    inFlight = true
    commandBuffer.commit()
  }

  // MARK: - Math

  private func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }

  /// Right-handed perspective with Metal's 0..1 clip-space depth.
  private static func perspective(fovyRadians: Float, aspect: Float, near: Float, far: Float)
    -> simd_float4x4
  {
    let ys = 1 / tanf(fovyRadians * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (
      SIMD4<Float>(xs, 0, 0, 0),
      SIMD4<Float>(0, ys, 0, 0),
      SIMD4<Float>(0, 0, zs, -1),
      SIMD4<Float>(0, 0, zs * near, 0)
    ))
  }

  private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(x, y, z, 1)
    return m
  }

  private static func rotationX(_ a: Float) -> simd_float4x4 {
    let c = cosf(a), s = sinf(a)
    return simd_float4x4(columns: (
      SIMD4<Float>(1, 0, 0, 0),
      SIMD4<Float>(0, c, s, 0),
      SIMD4<Float>(0, -s, c, 0),
      SIMD4<Float>(0, 0, 0, 1)
    ))
  }

  private static func rotationY(_ a: Float) -> simd_float4x4 {
    let c = cosf(a), s = sinf(a)
    return simd_float4x4(columns: (
      SIMD4<Float>(c, 0, -s, 0),
      SIMD4<Float>(0, 1, 0, 0),
      SIMD4<Float>(s, 0, c, 0),
      SIMD4<Float>(0, 0, 0, 1)
    ))
  }

  // MARK: - Shaders

  // Generated by tool/gen_shaders.py from one source shared with Android;
  // edit the generator, not this string.
  // BEGIN GENERATED SHADERS
  private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
      float3 position [[attribute(0)]];
      float3 normal   [[attribute(1)]];
      float2 uv       [[attribute(2)]];
      float4 tangent  [[attribute(3)]];
    };

    struct Uniforms {
      float4x4 mvp;
      float4x4 model;
      float4 cameraPos;
      float4 resolutionTime;  // x, y: target size in pixels; z: seconds
    };

    struct MaterialUniforms {
      float4 baseColor;
      float4 params;   // metallic, roughness, hasTexture, hasNormalMap
      float4 params2;  // normalScale, hasMetalRoughMap, clearcoat
    };

    struct StyleUniforms {
      float4 gradTop;
      float4 gradBottom;
      float4 specColor;
      float4 params;   // glossy, gloss, glossOverride, gradientMix
      float4 params2;  // sparkle
    };

    struct VertexOut {
      float4 position [[position]];
      float3 worldPos;
      float3 normal;
      float4 tangent;
      float3 obj;
      float2 uv;
    };

    vertex VertexOut glb_vertex(VertexIn in [[stage_in]],
                                constant Uniforms &u [[buffer(1)]]) {
      VertexOut out;
      out.position = u.mvp * float4(in.position, 1.0);
      out.worldPos = (u.model * float4(in.position, 1.0)).xyz;
      out.normal = (u.model * float4(in.normal, 0.0)).xyz;
      out.tangent = float4((u.model * float4(in.tangent.xyz, 0.0)).xyz, in.tangent.w);
      out.obj = in.position;
      out.uv = in.uv;
      return out;
    }

    constant float PI = 3.14159265;

    static float3 srgb2lin(float3 c) { return pow(max(c, float3(0.0)), float3(2.2)); }
    static float3 lin2srgb(float3 c) { return pow(max(c, float3(0.0)), float3(1.0 / 2.2)); }

    // ACES filmic fit: keeps midtones and saturation, rolls off highlights.
    static float3 tonemap(float3 x) {
        return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
    }

    // Sine-free hash: stable on mobile GPUs with large inputs.
    static float hash3(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }

    // Trilinear value noise, 0..1.
    static float noise3(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float n000 = hash3(i);
        float n100 = hash3(i + float3(1.0, 0.0, 0.0));
        float n010 = hash3(i + float3(0.0, 1.0, 0.0));
        float n110 = hash3(i + float3(1.0, 1.0, 0.0));
        float n001 = hash3(i + float3(0.0, 0.0, 1.0));
        float n101 = hash3(i + float3(1.0, 0.0, 1.0));
        float n011 = hash3(i + float3(0.0, 1.0, 1.0));
        float n111 = hash3(i + float3(1.0, 1.0, 1.0));
        return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
                   mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
    }

    // ~2.5% of 1/24-sized cells hold a tiny fleck with its own tilted facet. It
    // glints when that facet mirrors the key light toward the viewer, and
    // twinkles with time and view angle.
    static float sparkleTwinkle(float3 p, float t, float3 n, float3 v, float3 key) {
        float3 cell = floor(p * 24.0);
        float keep = step(0.975, hash3(cell));
        float phase = hash3(cell + 19.19);
        float3 rnd = float3(hash3(cell + 3.7), hash3(cell + 7.3), hash3(cell + 11.1));
        float d = length(fract(p * 24.0) - (rnd * 0.5 + 0.25));
        float dot01 = 1.0 - smoothstep(0.02, 0.14, d);
        float3 facet = normalize(n + (rnd - 0.5) * 1.2);
        float glint = pow(max(dot(reflect(-v, facet), key), 0.0), 12.0);
        float twinkle = 0.5 + 0.5 * sin(t * 5.0 + phase * 60.0 + dot(n, v) * 6.0);
        return keep * dot01 * twinkle * glint * 3.0;
    }

    // GGX normal distribution; a = roughness^2.
    static float distributionGGX(float NoH, float a) {
        float a2 = a * a;
        float d = NoH * NoH * (a2 - 1.0) + 1.0;
        return a2 / (PI * d * d);
    }

    // Smith-Schlick visibility, including the 1 / (4 NoL NoV) term.
    static float visibilitySmith(float NoV, float NoL, float a) {
        float k = a * 0.5;
        float gv = NoV / (NoV * (1.0 - k) + k);
        float gl = NoL / (NoL * (1.0 - k) + k);
        return gv * gl / max(4.0 * NoV * NoL, 0.0001);
    }

    static float3 fresnelSchlick(float3 f0, float cosTheta) {
        return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
    }

    // Analytic split-sum environment BRDF (Karis, "Physically Based Shading on
    // Mobile"): returns scale and bias for F0.
    static float2 envBRDF(float rough, float NoV) {
        float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
        float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
        float4 r = rough * c0 + c1;
        float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
        return float2(-1.04, 1.04) * a004 + r.zw;
    }

    // A spherical-Gaussian light seen through a GGX lobe of roughness^2 = a:
    // the lobes convolve, so rough surfaces see a wider, dimmer light with the
    // same energy.
    static float3 sgLight(float3 R, float3 dir, float sharpness, float a, float3 color) {
        float lobe = 2.0 / max(a * a, 0.0001);
        float s = sharpness * lobe / (sharpness + lobe);
        return color * (s / sharpness) * exp(s * (dot(R, dir) - 1.0));
    }

    // Procedural studio: dark floor, bright ceiling, a broad front softbox
    // behind the camera (so faces pointing at the viewer read as polished, not
    // black), a key softbox, a strip light and a kicker. Metals need this
    // contrast to read as metal.
    static float3 studioEnv(float3 R, float a, float3 top, float3 bottom) {
        float3 env = mix(bottom * 0.04, top * 0.35, smoothstep(-0.35 - a, 0.6 + a, R.y));
        env += sgLight(R, normalize(float3(0.15, 0.3, 1.0)), 5.0, a, top * 1.1);
        env += sgLight(R, normalize(float3(-0.45, 0.75, 0.5)), 24.0, a, top * 6.0);
        env += sgLight(R, normalize(float3(0.85, 0.15, 0.35)), 48.0, a, float3(3.0));
        env += sgLight(R, normalize(float3(-0.9, -0.1, 0.2)), 40.0, a, top * 1.5);
        env += sgLight(R, normalize(float3(0.0, -0.9, 0.4)), 10.0, a, bottom);
        return env;
    }

    // Diffuse light from the same studio, as a cheap hemisphere blend.
    static float3 studioIrradiance(float3 N, float3 top, float3 bottom) {
        return mix(bottom * 0.2, top * 0.55, N.y * 0.5 + 0.5);
    }

    // Diffuse + GGX specular from one directional light. Specular goes to
    // `spec`, diffuse is returned.
    static float3 directLight(float3 N, float3 V, float3 L, float3 radiance, float3 diffuseColor,
                     float3 F0, float a, float NoV, float g, thread float3 &spec) {
        float NoL = max(dot(N, L), 0.0);
        float3 H = normalize(L + V);
        float NoH = max(dot(N, H), 0.0);
        float VoH = max(dot(V, H), 0.0);
        float3 F = fresnelSchlick(F0, VoH);
        spec += radiance * distributionGGX(NoH, a) * visibilitySmith(NoV, NoL, a) * F * (PI * NoL * g);
        return radiance * diffuseColor * (1.0 - F * g) * NoL;
    }

    #define sampleBase(uv) baseTex.sample(smp, uv)
    #define sampleNormal(uv) normalTex.sample(smp, uv)
    #define sampleMr(uv) mrTex.sample(smp, uv)

    fragment float4 glb_fragment(VertexOut in [[stage_in]],
                                 bool frontFacing [[front_facing]],
                                 constant Uniforms &u [[buffer(1)]],
                                 constant MaterialUniforms &m [[buffer(2)]],
                                 constant StyleUniforms &s [[buffer(3)]],
                                 texture2d<float> baseTex [[texture(0)]],
                                 texture2d<float> normalTex [[texture(1)]],
                                 texture2d<float> mrTex [[texture(2)]],
                                 sampler smp [[sampler(0)]]) {
        float3 vNormal = in.normal;
        float4 vTangent = in.tangent;
        float3 vWorldPos = in.worldPos;
        float3 vObj = in.obj;
        float2 vUv = in.uv;
        float3 uCameraPos = u.cameraPos.xyz;
        float2 uResolution = u.resolutionTime.xy;
        float uTime = u.resolutionTime.z;
        // Metal's pixel origin is top-left; flip so y grows upwards like GL.
        float2 fragCoord = float2(in.position.x, uResolution.y - in.position.y);
        float4 uBaseColor = m.baseColor;
        float uMetallic = m.params.x;
        float uRoughness = m.params.y;
        float uHasTex = m.params.z;
        float uHasNormal = m.params.w;
        float uNormalScale = m.params2.x;
        float uHasMr = m.params2.y;
        float uClearcoat = m.params2.z;
        float uGlossy = s.params.x;
        float uGloss = s.params.y;
        float uGlossOverride = s.params.z;
        float uGradMix = s.params.w;
        float uSparkle = s.params2.x;
        float3 uGradTop = s.gradTop.xyz;
        float3 uGradBottom = s.gradBottom.xyz;
        float3 uSpecColor = s.specColor.xyz;

        // Matte mode zeroes every gloss term.
        float g = uGloss * uGlossy;
        float3 gradTop = srgb2lin(uGradTop);
        float3 gradBottom = srgb2lin(uGradBottom);

        // Geometric frame; flipped as a whole on back faces.
        float side = frontFacing ? 1.0 : -1.0;
        float3 n0 = normalize(vNormal);
        float3 t0 = normalize(vTangent.xyz - n0 * dot(n0, vTangent.xyz));
        float3 b0 = cross(n0, t0) * vTangent.w;
        float3 Ng = n0 * side;
        float3 V = normalize(uCameraPos - vWorldPos);

        // 1. Normal map (tangent space, glTF convention).
        float3 N = Ng;
        if (uHasNormal > 0.5) {
            float3 nm = sampleNormal(vUv).xyz * 2.0 - 1.0;
            nm.xy *= uNormalScale;
            N = normalize((t0 * nm.x + b0 * nm.y) * side + Ng * nm.z);
        }

        // 2. Micro-normal flecks drifting slowly with time.
        float3 q = vObj * 38.0 + uTime * 0.05;
        float3 nz = float3(noise3(q), noise3(q + 17.0), noise3(q + 41.0)) - 0.5;
        // Kept faint: stronger reads as grain/dirt on polished metal.
        N = normalize(N + nz * (0.025 * uSparkle * g));

        // 3. Material. baseColorFactor is linear in glTF; textures are sRGB.
        float3 base = (uHasTex > 0.5 ? srgb2lin(sampleBase(vUv).rgb) : float3(1.0)) * uBaseColor.rgb;
        float2 suv = fragCoord / uResolution;
        float3 grad = srgb2lin(mix(uGradBottom, uGradTop, suv.y));
        base = mix(base, grad * (0.35 + 0.65 * dot(base, float3(0.33))), uGradMix);

        float4 mr = uHasMr > 0.5 ? sampleMr(vUv) : float4(1.0);
        // Matte mode renders everything as a dielectric.
        float metalness = clamp(uMetallic * mr.b, 0.0, 1.0) * g;
        float roughM = clamp(uRoughness * mr.g, 0.0, 1.0);
        // Gloss override caps roughness: it can only polish, never roughen.
        float rough = mix(roughM, min(roughM, mix(0.45, 0.06, uGloss)), uGlossOverride);
        rough = max(rough, 0.07);
        float a = rough * rough;

        float3 F0 = mix(float3(0.04), base, metalness);
        float3 diffuseColor = base * (1.0 - metalness);
        float NoV = max(dot(N, V), 0.0001);

        // 4. Key, fill and rim lights, fixed relative to the camera.
        float3 spec = float3(0.0);
        float3 col = directLight(N, V, normalize(float3(-0.55, 0.80, 0.90)), float3(1.0),
                               diffuseColor, F0, a, NoV, g, spec);
        col += directLight(N, V, normalize(float3(0.85, -0.35, 0.50)), float3(0.35),
                           diffuseColor, F0, a, NoV, g, spec);
        col += directLight(N, V, normalize(float3(0.2, 0.5, -1.0)), float3(1.2),
                           diffuseColor, F0, a, NoV, g, spec);
        col += diffuseColor * studioIrradiance(N, gradTop, gradBottom);
        col += spec * srgb2lin(uSpecColor);

        // 5. Studio reflection, blurred by roughness and weighted by the
        //    split-sum Fresnel.
        float3 R = reflect(-V, N);
        float2 ab = envBRDF(rough, NoV);
        col += studioEnv(R, a, gradTop, gradBottom) * (F0 * ab.x + ab.y) * g;

        // 6. Clearcoat: a thin, nearly mirror-smooth layer on the geometric
        //    normal (ignores the normal map, like real lacquer).
        float coatW = mix(uClearcoat, 1.0, uGlossOverride) * g;
        float NoVc = max(dot(Ng, V), 0.0001);
        float Fc = 0.04 + 0.96 * pow(1.0 - NoVc, 5.0);
        float3 Lk = normalize(float3(-0.55, 0.80, 0.90));
        float3 Hk = normalize(Lk + V);
        float coatA = 0.0064;
        float3 coat = studioEnv(reflect(-V, Ng), coatA, gradTop, gradBottom) * Fc
                  + srgb2lin(uSpecColor) * distributionGGX(max(dot(Ng, Hk), 0.0), coatA)
                    * visibilitySmith(NoVc, max(dot(Ng, Lk), 0.0), coatA) * 0.04
                    * PI * max(dot(Ng, Lk), 0.0);
        col = col * (1.0 - coatW * Fc) + coat * coatW;

        // 7. Glitter, then tone map.
        col += float3(sparkleTwinkle(vObj, uTime, N, V, Lk)) * uSparkle * g;
        float3 outColor = lin2srgb(tonemap(col));

        return float4(outColor, 1.0);
    }
    """
  // END GENERATED SHADERS
}
