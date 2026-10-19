import CoreVideo
import Flutter
import Metal
import QuartzCore
import simd

// These match the structs of the same name in the Metal shader.
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

/// One GlbView: renders a model from the shared [GlbMetal] store into
/// IOSurface-backed pixel buffers that Flutter samples through
/// `copyPixelBuffer`.
final class GlbRenderer: NSObject, FlutterTexture {
  private static let bufferCount = 3

  private struct RenderTarget {
    let pixelBuffer: CVPixelBuffer
    let cvTexture: CVMetalTexture  // keeps the Metal texture's backing alive
    let texture: MTLTexture
  }

  private let metal: GlbMetal
  private let width: Int
  private let height: Int
  private let autoRotate: Double
  private let logTimings: Bool
  private weak var registry: FlutterTextureRegistry?

  private let depthTexture: MTLTexture
  /// 4x MSAA color target, resolved into the current pixel buffer.
  private let msaaTexture: MTLTexture
  private let textureCache: CVMetalTextureCache
  private let targets: [RenderTarget]

  // Shared with the Flutter raster thread.
  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  // Main-thread state.
  private var textureId: Int64 = 0
  private var displayLink: CADisplayLink?
  private var model: GpuModel?
  private var overrides: [Int: GpuOverride] = [:]
  private var overrideGeneration = 0
  private var nextTarget = 0
  private var inFlight = false
  private var dirty = true
  private var disposed = false
  private var angle: Double = 0
  private var lastTimestamp: CFTimeInterval = 0
  private var yaw: Float = 0
  private var pitch: Float = 0
  private var distance: Float = 3.2
  private var style = GlbStyle()
  private var startTimestamp: CFTimeInterval = 0
  private let createdAt = CACurrentMediaTime()
  private var firstFrameLogged = false
  private let projection: simd_float4x4

  init(
    metal: GlbMetal, width: Int, height: Int, autoRotate: Double, logTimings: Bool,
    registry: FlutterTextureRegistry
  ) throws {
    self.metal = metal
    self.width = width
    self.height = height
    self.autoRotate = autoRotate
    self.logTimings = logTimings
    self.registry = registry
    let device = metal.device

    func multisampleDescriptor(_ format: MTLPixelFormat) -> MTLTextureDescriptor {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: width, height: height, mipmapped: false)
      d.textureType = .type2DMultisample
      d.sampleCount = GlbMetal.sampleCount
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
    model = nil
    overrides = [:]
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

  /// Draws the cached model [key]. Returns false if it isn't cached.
  func setModel(_ key: String) -> Bool {
    guard let model = metal.model(key) else { return false }
    self.model = model
    dirty = true
    return true
  }

  /// Replaces this view's overrides once their textures are decoded;
  /// [completion] runs on the main thread.
  func setOverrides(_ list: [OverrideData], completion: @escaping () -> Void) {
    overrideGeneration += 1
    let generation = overrideGeneration
    let images = list.flatMap { [$0.texture, $0.normalTexture, $0.metallicRoughnessTexture] }
    metal.loadTextures(images) { textures in
      DispatchQueue.main.async { [weak self] in
        guard let self = self, !self.disposed, generation == self.overrideGeneration else {
          completion()
          return
        }
        var built: [Int: GpuOverride] = [:]
        for (i, o) in list.enumerated() {
          let c = o.baseColor
          built[o.index] = GpuOverride(
            texture: textures[i * 3], normalTexture: textures[i * 3 + 1], mrTexture: textures[i * 3 + 2],
            baseColor: c.flatMap { $0.count >= 4 ? SIMD4<Float>($0[0], $0[1], $0[2], $0[3]) : nil })
        }
        self.overrides = built
        self.dirty = true
        completion()
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
    // Skip while the previous frame is still on the GPU or the shared
    // pipeline is still compiling; `dirty` stays set.
    guard dirty, !inFlight, !disposed, let pipeline = metal.pipeline else { return }
    dirty = false
    render(pipeline)
  }

  private func render(_ pipeline: MTLRenderPipelineState) {
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

    guard let commandBuffer = metal.queue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
    else { return }

    let modelMatrix =
      GlbRenderer.rotationX(radians(pitch))
      * GlbRenderer.rotationY(radians(yaw + Float(angle)))
    let view = GlbRenderer.translation(0, 0, -distance)
    var uniforms = Uniforms(
      mvp: projection * view * modelMatrix,
      model: modelMatrix,
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
    encoder.setDepthStencilState(metal.depthState)
    encoder.setCullMode(.none)
    encoder.setFrontFacing(.counterClockwise)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&styleUniforms, length: MemoryLayout<StyleUniforms>.stride, index: 3)
    encoder.setFragmentSamplerState(metal.sampler, index: 0)
    for (i, mesh) in (model?.meshes ?? []).enumerated() {
      let o = overrides[i]
      let texture = o?.texture ?? mesh.texture
      let normalTexture = o?.normalTexture ?? mesh.normalTexture
      let mrTexture = o?.mrTexture ?? mesh.mrTexture
      var material = MaterialUniforms(
        baseColor: o?.baseColor ?? mesh.baseColor,
        params: SIMD4<Float>(
          mesh.metallic, mesh.roughness, texture == nil ? 0 : 1, normalTexture == nil ? 0 : 1),
        params2: SIMD4<Float>(mesh.normalScale, mrTexture == nil ? 0 : 1, mesh.clearcoat, 0))
      encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
      encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialUniforms>.stride, index: 2)
      encoder.setFragmentTexture(texture ?? metal.whiteTexture, index: 0)
      encoder.setFragmentTexture(normalTexture ?? metal.whiteTexture, index: 1)
      encoder.setFragmentTexture(mrTexture ?? metal.whiteTexture, index: 2)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
        indexBuffer: mesh.indexBuffer, indexBufferOffset: 0)
    }
    encoder.endEncoding()

    let pixelBuffer = target.pixelBuffer
    let hasModel = model != nil
    commandBuffer.addCompletedHandler { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.inFlight = false
        guard !self.disposed else { return }
        self.lock.lock()
        self.latest = pixelBuffer
        self.lock.unlock()
        self.registry?.textureFrameAvailable(self.textureId)
        if self.logTimings && hasModel && !self.firstFrameLogged {
          self.firstFrameLogged = true
          NSLog(
            "GlbView timing: view %lld first model frame %.1f ms after create", self.textureId,
            (CACurrentMediaTime() - self.createdAt) * 1000)
        }
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
}
