package dev.samandar.glbview

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicReference

/** GPU-ready data for one draw call, as produced by the Dart parser. */
internal class PrimitiveData(
    /** Interleaved position(3) normal(3) uv(2) tangent(4), non-indexed triangles. */
    val vertices: FloatArray,
    val baseColor: FloatArray,
    /** Encoded PNG/JPEG bytes. */
    val texture: ByteArray?,
    val metallic: Float,
    val roughness: Float,
    val normalTexture: ByteArray?,
    val normalScale: Float,
    val metallicRoughnessTexture: ByteArray?,
    val clearcoat: Float,
)

/** Shading parameters from `setStyle`. Colors are sRGB components 0..1. */
internal data class GlbStyle(
    val glossy: Boolean = true,
    val gloss: Float = 1f,
    val glossOverridesMaterial: Boolean = true,
    val gradientTop: FloatArray = floatArrayOf(0.937f, 0.953f, 1f),
    val gradientBottom: FloatArray = floatArrayOf(0.227f, 0.247f, 0.333f),
    val gradientMix: Float = 0f,
    val sparkle: Float = 0.5f,
    val specularColor: FloatArray = floatArrayOf(1f, 1f, 1f),
) {
    /** Sparkle drifts and twinkles over time, so it needs continuous frames. */
    val animated: Boolean get() = glossy && gloss > 0f && sparkle > 0f
}

/**
 * Renders a model with OpenGL ES 2.0 into a Flutter SurfaceTexture on a
 * dedicated thread with its own EGL context.
 */
internal class GlbRenderer(
    private val entry: TextureRegistry.SurfaceTextureEntry,
    private val width: Int,
    private val height: Int,
    /** Degrees per second; 0 disables auto rotation. */
    private val autoRotate: Float,
) {
    private val surface: Surface
    private val pendingModel = AtomicReference<List<PrimitiveData>?>(null)

    @Volatile private var running = true
    @Volatile private var dirty = true
    @Volatile private var yaw = 0f
    @Volatile private var pitch = 0f
    @Volatile private var distance = 3.2f
    @Volatile private var style = GlbStyle()

    private val thread: Thread

    // GL-thread state.
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var whiteTexture = 0
    private var meshes = emptyList<GpuMesh>()
    private var aPos = 0
    private var aNormal = 0
    private var aUv = 0
    private var aTangent = 0
    private var uNormalTex = 0
    private var uMrTex = 0
    private var uHasNormal = 0
    private var uHasMr = 0
    private var uNormalScale = 0
    private var uClearcoat = 0
    private var uMvp = 0
    private var uModel = 0
    private var uBaseColor = 0
    private var uCameraPos = 0
    private var uTex = 0
    private var uTime = 0
    private var uResolution = 0
    private var uHasTex = 0
    private var uMetallic = 0
    private var uRoughness = 0
    private var uGlossy = 0
    private var uGloss = 0
    private var uGlossOverride = 0
    private var uGradTop = 0
    private var uGradBottom = 0
    private var uGradMix = 0
    private var uSparkle = 0
    private var uSpecColor = 0

    private val proj = FloatArray(16)
    private val view = FloatArray(16)
    private val model = FloatArray(16)
    private val rotX = FloatArray(16)
    private val rotY = FloatArray(16)
    private val viewModel = FloatArray(16)
    private val mvp = FloatArray(16)

    private class GpuMesh(
        val vbo: Int,
        val vertexCount: Int,
        val color: FloatArray,
        val texture: Int,
        val metallic: Float,
        val roughness: Float,
        val normalTexture: Int,
        val normalScale: Float,
        val mrTexture: Int,
        val clearcoat: Float,
    ) {
        val textures get() = intArrayOf(texture, normalTexture, mrTexture).filter { it != 0 }
    }

    init {
        val surfaceTexture = entry.surfaceTexture()
        surfaceTexture.setDefaultBufferSize(width, height)
        surface = Surface(surfaceTexture)
        thread = Thread(::renderLoop, "GlbRenderer-${entry.id()}").apply { start() }
    }

    fun setCamera(yaw: Float, pitch: Float, distance: Float) {
        this.yaw = yaw
        this.pitch = pitch
        this.distance = distance
        dirty = true
    }

    fun setStyle(style: GlbStyle) {
        this.style = style
        dirty = true
    }

    /** May be called from any thread; the upload happens on the GL thread. */
    fun loadModel(primitives: List<PrimitiveData>) {
        pendingModel.set(primitives)
        dirty = true
    }

    /** Stops rendering and releases everything. Call on the platform thread. */
    fun dispose() {
        if (!running) return
        running = false
        thread.interrupt()
        try {
            thread.join(1000)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        surface.release()
        if (Looper.myLooper() == Looper.getMainLooper()) {
            entry.release()
        } else {
            Handler(Looper.getMainLooper()).post { entry.release() }
        }
    }

    // ---------------------------------------------------------------------
    // GL thread

    private fun renderLoop() {
        try {
            initEgl()
            initGl()
            var angle = 0f
            val startNs = System.nanoTime()
            var last = startNs
            while (running) {
                val frameStart = System.nanoTime()
                val dt = (frameStart - last) / 1e9f
                last = frameStart

                pendingModel.getAndSet(null)?.let { uploadModel(it) }

                if (autoRotate != 0f) {
                    angle = (angle + autoRotate * dt) % 360f
                    dirty = true
                }
                if (style.animated) dirty = true
                if (dirty) {
                    dirty = false
                    // Wrapped so float precision in the shader stays good.
                    val time = ((frameStart - startNs) / 1e9 % 1000.0).toFloat()
                    drawFrame(angle, time)
                    if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
                        val error = EGL14.eglGetError()
                        if (error == EGL14.EGL_BAD_SURFACE || error == EGL14.EGL_BAD_NATIVE_WINDOW) {
                            Log.w(TAG, "Surface lost (0x${Integer.toHexString(error)}), stopping")
                            break
                        }
                    }
                }

                val sleepMs = (FRAME_NS - (System.nanoTime() - frameStart)) / 1_000_000L
                if (sleepMs > 0) Thread.sleep(sleepMs)
            }
        } catch (_: InterruptedException) {
            // dispose() was called.
        } catch (t: Throwable) {
            Log.e(TAG, "Render thread failed", t)
        } finally {
            releaseGl()
            releaseEgl()
        }
    }

    private fun initEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "No EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) { "eglInitialize failed" }

        // Prefer 4x MSAA; fall back to a plain config if the driver has none.
        val config = chooseConfig(samples = 4) ?: chooseConfig(samples = 0)
            ?: throw IllegalStateException("No suitable EGL config")

        eglContext = EGL14.eglCreateContext(
            eglDisplay, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }

        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        check(eglSurface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed" }
        check(EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) { "eglMakeCurrent failed" }
    }

    private fun chooseConfig(samples: Int): EGLConfig? {
        val attribs = mutableListOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_DEPTH_SIZE, 16,
        )
        if (samples > 0) {
            attribs += listOf(EGL14.EGL_SAMPLE_BUFFERS, 1, EGL14.EGL_SAMPLES, samples)
        }
        attribs += EGL14.EGL_NONE
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        val ok = EGL14.eglChooseConfig(eglDisplay, attribs.toIntArray(), 0, configs, 0, 1, count, 0)
        return if (ok && count[0] > 0) configs[0] else null
    }

    private fun releaseEgl() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
        if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
        // No eglTerminate: the default display is shared with Flutter's own renderer.
        EGL14.eglReleaseThread()
        eglSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }

    private fun initGl() {
        program = linkProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        aPos = GLES20.glGetAttribLocation(program, "aPos")
        aNormal = GLES20.glGetAttribLocation(program, "aNormal")
        aUv = GLES20.glGetAttribLocation(program, "aUv")
        aTangent = GLES20.glGetAttribLocation(program, "aTangent")
        uNormalTex = GLES20.glGetUniformLocation(program, "uNormalTex")
        uMrTex = GLES20.glGetUniformLocation(program, "uMrTex")
        uHasNormal = GLES20.glGetUniformLocation(program, "uHasNormal")
        uHasMr = GLES20.glGetUniformLocation(program, "uHasMr")
        uNormalScale = GLES20.glGetUniformLocation(program, "uNormalScale")
        uClearcoat = GLES20.glGetUniformLocation(program, "uClearcoat")
        uMvp = GLES20.glGetUniformLocation(program, "uMvp")
        uModel = GLES20.glGetUniformLocation(program, "uModel")
        uBaseColor = GLES20.glGetUniformLocation(program, "uBaseColor")
        uCameraPos = GLES20.glGetUniformLocation(program, "uCameraPos")
        uTex = GLES20.glGetUniformLocation(program, "uTex")
        uTime = GLES20.glGetUniformLocation(program, "uTime")
        uResolution = GLES20.glGetUniformLocation(program, "uResolution")
        uHasTex = GLES20.glGetUniformLocation(program, "uHasTex")
        uMetallic = GLES20.glGetUniformLocation(program, "uMetallic")
        uRoughness = GLES20.glGetUniformLocation(program, "uRoughness")
        uGlossy = GLES20.glGetUniformLocation(program, "uGlossy")
        uGloss = GLES20.glGetUniformLocation(program, "uGloss")
        uGlossOverride = GLES20.glGetUniformLocation(program, "uGlossOverride")
        uGradTop = GLES20.glGetUniformLocation(program, "uGradTop")
        uGradBottom = GLES20.glGetUniformLocation(program, "uGradBottom")
        uGradMix = GLES20.glGetUniformLocation(program, "uGradMix")
        uSparkle = GLES20.glGetUniformLocation(program, "uSparkle")
        uSpecColor = GLES20.glGetUniformLocation(program, "uSpecColor")

        whiteTexture = genTexture()
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, whiteTexture)
        val white = ByteBuffer.allocateDirect(4).put(byteArrayOf(-1, -1, -1, -1)).apply { position(0) }
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, 1, 1, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, white,
        )
        setSampling(powerOfTwo = false)

        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        GLES20.glDepthFunc(GLES20.GL_LEQUAL)
        GLES20.glDisable(GLES20.GL_CULL_FACE)
        GLES20.glFrontFace(GLES20.GL_CCW)

        val aspect = width.toFloat() / height.toFloat()
        Matrix.perspectiveM(proj, 0, FOV_DEGREES, aspect, NEAR, FAR)
    }

    private fun releaseGl() {
        if (eglContext == EGL14.EGL_NO_CONTEXT) return
        deleteMeshes()
        if (whiteTexture != 0) GLES20.glDeleteTextures(1, intArrayOf(whiteTexture), 0)
        if (program != 0) GLES20.glDeleteProgram(program)
        whiteTexture = 0
        program = 0
    }

    private fun uploadModel(primitives: List<PrimitiveData>) {
        deleteMeshes()
        val maxSize = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, it, 0) }[0]
        val uploaded = ArrayList<GpuMesh>(primitives.size)
        for (p in primitives) {
            val count = p.vertices.size / FLOATS_PER_VERTEX
            if (count == 0) continue
            val buffer = ByteBuffer.allocateDirect(count * STRIDE_BYTES)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
                .put(p.vertices, 0, count * FLOATS_PER_VERTEX)
            buffer.position(0)
            val vbo = IntArray(1).also { GLES20.glGenBuffers(1, it, 0) }[0]
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo)
            GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, count * STRIDE_BYTES, buffer, GLES20.GL_STATIC_DRAW)

            val color = if (p.baseColor.size >= 4) p.baseColor.copyOf(4) else floatArrayOf(1f, 1f, 1f, 1f)
            val texture = p.texture?.let { uploadTexture(it, maxSize) } ?: 0
            val normalTexture = p.normalTexture?.let { uploadTexture(it, maxSize) } ?: 0
            val mrTexture = p.metallicRoughnessTexture?.let { uploadTexture(it, maxSize) } ?: 0
            uploaded += GpuMesh(
                vbo, count, color, texture, p.metallic, p.roughness,
                normalTexture, p.normalScale, mrTexture, p.clearcoat,
            )
        }
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        meshes = uploaded
    }

    private fun uploadTexture(bytes: ByteArray, maxSize: Int): Int {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            Log.w(TAG, "Could not decode texture image")
            return 0
        }
        var sample = 1
        while (bounds.outWidth / sample > maxSize || bounds.outHeight / sample > maxSize) sample *= 2

        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inPremultiplied = false
            inScaled = false
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return 0
        return try {
            val id = genTexture()
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            val pot = isPowerOfTwo(bitmap.width) && isPowerOfTwo(bitmap.height)
            if (pot) GLES20.glGenerateMipmap(GLES20.GL_TEXTURE_2D)
            setSampling(pot)
            id
        } finally {
            bitmap.recycle()
        }
    }

    private fun deleteMeshes() {
        if (meshes.isEmpty()) return
        GLES20.glDeleteBuffers(meshes.size, meshes.map { it.vbo }.toIntArray(), 0)
        val textures = meshes.flatMap { it.textures }.toIntArray()
        if (textures.isNotEmpty()) GLES20.glDeleteTextures(textures.size, textures, 0)
        meshes = emptyList()
    }

    private fun drawFrame(angle: Float, time: Float) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        if (meshes.isEmpty()) return

        val d = distance
        Matrix.setLookAtM(view, 0, 0f, 0f, d, 0f, 0f, 0f, 0f, 1f, 0f)
        Matrix.setRotateM(rotX, 0, pitch, 1f, 0f, 0f)
        Matrix.setRotateM(rotY, 0, yaw + angle, 0f, 1f, 0f)
        Matrix.multiplyMM(model, 0, rotX, 0, rotY, 0)
        Matrix.multiplyMM(viewModel, 0, view, 0, model, 0)
        Matrix.multiplyMM(mvp, 0, proj, 0, viewModel, 0)

        GLES20.glUseProgram(program)
        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0)
        GLES20.glUniformMatrix4fv(uModel, 1, false, model, 0)
        GLES20.glUniform3f(uCameraPos, 0f, 0f, d)
        GLES20.glUniform1i(uTex, 0)
        GLES20.glUniform1i(uNormalTex, 1)
        GLES20.glUniform1i(uMrTex, 2)
        GLES20.glUniform1f(uTime, time)
        GLES20.glUniform2f(uResolution, width.toFloat(), height.toFloat())
        val st = style
        GLES20.glUniform1f(uGlossy, if (st.glossy) 1f else 0f)
        GLES20.glUniform1f(uGloss, st.gloss)
        GLES20.glUniform1f(uGlossOverride, if (st.glossOverridesMaterial) 1f else 0f)
        GLES20.glUniform3fv(uGradTop, 1, st.gradientTop, 0)
        GLES20.glUniform3fv(uGradBottom, 1, st.gradientBottom, 0)
        GLES20.glUniform1f(uGradMix, st.gradientMix)
        GLES20.glUniform1f(uSparkle, st.sparkle)
        GLES20.glUniform3fv(uSpecColor, 1, st.specularColor, 0)

        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glEnableVertexAttribArray(aNormal)
        GLES20.glEnableVertexAttribArray(aUv)
        GLES20.glEnableVertexAttribArray(aTangent)
        for (mesh in meshes) {
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, mesh.vbo)
            GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, STRIDE_BYTES, 0)
            GLES20.glVertexAttribPointer(aNormal, 3, GLES20.GL_FLOAT, false, STRIDE_BYTES, 12)
            GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, STRIDE_BYTES, 24)
            GLES20.glVertexAttribPointer(aTangent, 4, GLES20.GL_FLOAT, false, STRIDE_BYTES, 32)
            GLES20.glUniform4fv(uBaseColor, 1, mesh.color, 0)
            GLES20.glUniform1f(uHasTex, if (mesh.texture != 0) 1f else 0f)
            GLES20.glUniform1f(uMetallic, mesh.metallic)
            GLES20.glUniform1f(uRoughness, mesh.roughness)
            GLES20.glUniform1f(uHasNormal, if (mesh.normalTexture != 0) 1f else 0f)
            GLES20.glUniform1f(uHasMr, if (mesh.mrTexture != 0) 1f else 0f)
            GLES20.glUniform1f(uNormalScale, mesh.normalScale)
            GLES20.glUniform1f(uClearcoat, mesh.clearcoat)
            bindTexture(0, mesh.texture)
            bindTexture(1, mesh.normalTexture)
            bindTexture(2, mesh.mrTexture)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, mesh.vertexCount)
        }
        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aNormal)
        GLES20.glDisableVertexAttribArray(aUv)
        GLES20.glDisableVertexAttribArray(aTangent)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
    }

    // ---------------------------------------------------------------------
    // Helpers

    private fun bindTexture(unit: Int, texture: Int) {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, if (texture != 0) texture else whiteTexture)
    }

    private fun genTexture(): Int = IntArray(1).also { GLES20.glGenTextures(1, it, 0) }[0]

    private fun setSampling(powerOfTwo: Boolean) {
        val t = GLES20.GL_TEXTURE_2D
        if (powerOfTwo) {
            GLES20.glTexParameteri(t, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR_MIPMAP_LINEAR)
            GLES20.glTexParameteri(t, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_REPEAT)
            GLES20.glTexParameteri(t, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_REPEAT)
        } else {
            GLES20.glTexParameteri(t, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(t, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(t, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }
        GLES20.glTexParameteri(t, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    }

    private fun isPowerOfTwo(n: Int) = n > 0 && (n and (n - 1)) == 0

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("Shader compile failed: $log")
        }
        return shader
    }

    private fun linkProgram(vertex: String, fragment: String): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertex)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragment)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vs)
        GLES20.glAttachShader(program, fs)
        GLES20.glLinkProgram(program)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("Program link failed: $log")
        }
        return program
    }

    private companion object {
        const val TAG = "GlbView"
        const val FRAME_NS = 16_666_667L
        const val FLOATS_PER_VERTEX = 12
        const val STRIDE_BYTES = FLOATS_PER_VERTEX * 4
        const val FOV_DEGREES = 40f
        const val NEAR = 0.1f
        const val FAR = 100f

        // Generated by tool/gen_shaders.py from one source shared with iOS;
        // edit the generator, not these strings.
        // BEGIN GENERATED SHADERS
        const val VERTEX_SHADER = """
uniform mat4 uMvp;
uniform mat4 uModel;
attribute vec3 aPos;
attribute vec3 aNormal;
attribute vec2 aUv;
attribute vec4 aTangent;
varying vec3 vNormal;
varying vec4 vTangent;
varying vec3 vWorldPos;
varying vec3 vObj;
varying vec2 vUv;
void main() {
    vWorldPos = (uModel * vec4(aPos, 1.0)).xyz;
    vNormal = (uModel * vec4(aNormal, 0.0)).xyz;
    vTangent = vec4((uModel * vec4(aTangent.xyz, 0.0)).xyz, aTangent.w);
    vObj = aPos;
    vUv = aUv;
    gl_Position = uMvp * vec4(aPos, 1.0);
}
"""

        const val FRAGMENT_SHADER = """
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec4 uBaseColor;
uniform vec3 uCameraPos;
uniform sampler2D uTex;
uniform sampler2D uNormalTex;
uniform sampler2D uMrTex;
uniform float uHasTex;
uniform float uHasNormal;
uniform float uHasMr;
uniform float uNormalScale;
uniform float uClearcoat;
uniform float uTime;
uniform vec2 uResolution;
uniform float uMetallic;
uniform float uRoughness;
uniform float uGlossy;
uniform float uGloss;
uniform float uGlossOverride;
uniform vec3 uGradTop;
uniform vec3 uGradBottom;
uniform float uGradMix;
uniform float uSparkle;
uniform vec3 uSpecColor;
varying vec3 vNormal;
varying vec4 vTangent;
varying vec3 vWorldPos;
varying vec3 vObj;
varying vec2 vUv;

#define sampleBase(uv) texture2D(uTex, uv)
#define sampleNormal(uv) texture2D(uNormalTex, uv)
#define sampleMr(uv) texture2D(uMrTex, uv)

const float PI = 3.14159265;

vec3 srgb2lin(vec3 c) { return pow(max(c, vec3(0.0)), vec3(2.2)); }
vec3 lin2srgb(vec3 c) { return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2)); }

// ACES filmic fit: keeps midtones and saturation, rolls off highlights.
vec3 tonemap(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// Sine-free hash: stable on mobile GPUs with large inputs.
float hash3(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

// Trilinear value noise, 0..1.
float noise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash3(i);
    float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// ~2.5% of 1/24-sized cells hold a tiny fleck with its own tilted facet. It
// glints when that facet mirrors the key light toward the viewer, and
// twinkles with time and view angle.
float sparkleTwinkle(vec3 p, float t, vec3 n, vec3 v, vec3 key) {
    vec3 cell = floor(p * 24.0);
    float keep = step(0.975, hash3(cell));
    float phase = hash3(cell + 19.19);
    vec3 rnd = vec3(hash3(cell + 3.7), hash3(cell + 7.3), hash3(cell + 11.1));
    float d = length(fract(p * 24.0) - (rnd * 0.5 + 0.25));
    float dot01 = 1.0 - smoothstep(0.02, 0.14, d);
    vec3 facet = normalize(n + (rnd - 0.5) * 1.2);
    float glint = pow(max(dot(reflect(-v, facet), key), 0.0), 12.0);
    float twinkle = 0.5 + 0.5 * sin(t * 5.0 + phase * 60.0 + dot(n, v) * 6.0);
    return keep * dot01 * twinkle * glint * 3.0;
}

// GGX normal distribution; a = roughness^2.
float distributionGGX(float NoH, float a) {
    float a2 = a * a;
    float d = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

// Smith-Schlick visibility, including the 1 / (4 NoL NoV) term.
float visibilitySmith(float NoV, float NoL, float a) {
    float k = a * 0.5;
    float gv = NoV / (NoV * (1.0 - k) + k);
    float gl = NoL / (NoL * (1.0 - k) + k);
    return gv * gl / max(4.0 * NoV * NoL, 0.0001);
}

vec3 fresnelSchlick(vec3 f0, float cosTheta) {
    return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
}

// Analytic split-sum environment BRDF (Karis, "Physically Based Shading on
// Mobile"): returns scale and bias for F0.
vec2 envBRDF(float rough, float NoV) {
    vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = rough * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    return vec2(-1.04, 1.04) * a004 + r.zw;
}

// A spherical-Gaussian light seen through a GGX lobe of roughness^2 = a:
// the lobes convolve, so rough surfaces see a wider, dimmer light with the
// same energy.
vec3 sgLight(vec3 R, vec3 dir, float sharpness, float a, vec3 color) {
    float lobe = 2.0 / max(a * a, 0.0001);
    float s = sharpness * lobe / (sharpness + lobe);
    return color * (s / sharpness) * exp(s * (dot(R, dir) - 1.0));
}

// Procedural studio: dark floor, bright ceiling, a broad front softbox
// behind the camera (so faces pointing at the viewer read as polished, not
// black), a key softbox, a strip light and a kicker. Metals need this
// contrast to read as metal.
vec3 studioEnv(vec3 R, float a, vec3 top, vec3 bottom) {
    vec3 env = mix(bottom * 0.04, top * 0.35, smoothstep(-0.35 - a, 0.6 + a, R.y));
    env += sgLight(R, normalize(vec3(0.15, 0.3, 1.0)), 5.0, a, top * 1.1);
    env += sgLight(R, normalize(vec3(-0.45, 0.75, 0.5)), 24.0, a, top * 6.0);
    env += sgLight(R, normalize(vec3(0.85, 0.15, 0.35)), 48.0, a, vec3(3.0));
    env += sgLight(R, normalize(vec3(-0.9, -0.1, 0.2)), 40.0, a, top * 1.5);
    env += sgLight(R, normalize(vec3(0.0, -0.9, 0.4)), 10.0, a, bottom);
    return env;
}

// Diffuse light from the same studio, as a cheap hemisphere blend.
vec3 studioIrradiance(vec3 N, vec3 top, vec3 bottom) {
    return mix(bottom * 0.2, top * 0.55, N.y * 0.5 + 0.5);
}

// Diffuse + GGX specular from one directional light. Specular goes to
// `spec`, diffuse is returned.
vec3 directLight(vec3 N, vec3 V, vec3 L, vec3 radiance, vec3 diffuseColor,
                 vec3 F0, float a, float NoV, float g, inout vec3 spec) {
    float NoL = max(dot(N, L), 0.0);
    vec3 H = normalize(L + V);
    float NoH = max(dot(N, H), 0.0);
    float VoH = max(dot(V, H), 0.0);
    vec3 F = fresnelSchlick(F0, VoH);
    spec += radiance * distributionGGX(NoH, a) * visibilitySmith(NoV, NoL, a) * F * (PI * NoL * g);
    return radiance * diffuseColor * (1.0 - F * g) * NoL;
}

void main() {
    bool frontFacing = gl_FrontFacing;
    vec2 fragCoord = gl_FragCoord.xy;

    // Matte mode zeroes every gloss term.
    float g = uGloss * uGlossy;
    vec3 gradTop = srgb2lin(uGradTop);
    vec3 gradBottom = srgb2lin(uGradBottom);

    // Geometric frame; flipped as a whole on back faces.
    float side = frontFacing ? 1.0 : -1.0;
    vec3 n0 = normalize(vNormal);
    vec3 t0 = normalize(vTangent.xyz - n0 * dot(n0, vTangent.xyz));
    vec3 b0 = cross(n0, t0) * vTangent.w;
    vec3 Ng = n0 * side;
    vec3 V = normalize(uCameraPos - vWorldPos);

    // 1. Normal map (tangent space, glTF convention).
    vec3 N = Ng;
    if (uHasNormal > 0.5) {
        vec3 nm = sampleNormal(vUv).xyz * 2.0 - 1.0;
        nm.xy *= uNormalScale;
        N = normalize((t0 * nm.x + b0 * nm.y) * side + Ng * nm.z);
    }

    // 2. Micro-normal flecks drifting slowly with time.
    vec3 q = vObj * 38.0 + uTime * 0.05;
    vec3 nz = vec3(noise3(q), noise3(q + 17.0), noise3(q + 41.0)) - 0.5;
    // Kept faint: stronger reads as grain/dirt on polished metal.
    N = normalize(N + nz * (0.025 * uSparkle * g));

    // 3. Material. baseColorFactor is linear in glTF; textures are sRGB.
    vec3 base = (uHasTex > 0.5 ? srgb2lin(sampleBase(vUv).rgb) : vec3(1.0)) * uBaseColor.rgb;
    vec2 suv = fragCoord / uResolution;
    vec3 grad = srgb2lin(mix(uGradBottom, uGradTop, suv.y));
    base = mix(base, grad * (0.35 + 0.65 * dot(base, vec3(0.33))), uGradMix);

    vec4 mr = uHasMr > 0.5 ? sampleMr(vUv) : vec4(1.0);
    // Matte mode renders everything as a dielectric.
    float metalness = clamp(uMetallic * mr.b, 0.0, 1.0) * g;
    float roughM = clamp(uRoughness * mr.g, 0.0, 1.0);
    // Gloss override caps roughness: it can only polish, never roughen.
    float rough = mix(roughM, min(roughM, mix(0.45, 0.06, uGloss)), uGlossOverride);
    rough = max(rough, 0.07);
    float a = rough * rough;

    vec3 F0 = mix(vec3(0.04), base, metalness);
    vec3 diffuseColor = base * (1.0 - metalness);
    float NoV = max(dot(N, V), 0.0001);

    // 4. Key, fill and rim lights, fixed relative to the camera.
    vec3 spec = vec3(0.0);
    vec3 col = directLight(N, V, normalize(vec3(-0.55, 0.80, 0.90)), vec3(1.0),
                           diffuseColor, F0, a, NoV, g, spec);
    col += directLight(N, V, normalize(vec3(0.85, -0.35, 0.50)), vec3(0.35),
                       diffuseColor, F0, a, NoV, g, spec);
    col += directLight(N, V, normalize(vec3(0.2, 0.5, -1.0)), vec3(1.2),
                       diffuseColor, F0, a, NoV, g, spec);
    col += diffuseColor * studioIrradiance(N, gradTop, gradBottom);
    col += spec * srgb2lin(uSpecColor);

    // 5. Studio reflection, blurred by roughness and weighted by the
    //    split-sum Fresnel.
    vec3 R = reflect(-V, N);
    vec2 ab = envBRDF(rough, NoV);
    col += studioEnv(R, a, gradTop, gradBottom) * (F0 * ab.x + ab.y) * g;

    // 6. Clearcoat: a thin, nearly mirror-smooth layer on the geometric
    //    normal (ignores the normal map, like real lacquer).
    float coatW = mix(uClearcoat, 1.0, uGlossOverride) * g;
    float NoVc = max(dot(Ng, V), 0.0001);
    float Fc = 0.04 + 0.96 * pow(1.0 - NoVc, 5.0);
    vec3 Lk = normalize(vec3(-0.55, 0.80, 0.90));
    vec3 Hk = normalize(Lk + V);
    float coatA = 0.0064;
    vec3 coat = studioEnv(reflect(-V, Ng), coatA, gradTop, gradBottom) * Fc
              + srgb2lin(uSpecColor) * distributionGGX(max(dot(Ng, Hk), 0.0), coatA)
                * visibilitySmith(NoVc, max(dot(Ng, Lk), 0.0), coatA) * 0.04
                * PI * max(dot(Ng, Lk), 0.0);
    col = col * (1.0 - coatW * Fc) + coat * coatW;

    // 7. Glitter, then tone map.
    col += vec3(sparkleTwinkle(vObj, uTime, N, V, Lk)) * uSparkle * g;
    vec3 outColor = lin2srgb(tonemap(col));

    gl_FragColor = vec4(outColor, 1.0);
}
"""
        // END GENERATED SHADERS
    }
}
