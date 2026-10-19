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
import java.nio.Buffer
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** GPU-ready data for one draw call, as produced by the Dart parser. */
internal class PrimitiveData(
    /** Interleaved position(3) normal(3) uv(2) tangent(4), unique vertices. */
    val vertices: FloatArray,
    /** Triangle list into [vertices]. */
    val indices: IntArray,
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

/** Per-view replacement of one primitive's material inputs. */
internal class OverrideData(
    val index: Int,
    val texture: ByteArray?,
    val normalTexture: ByteArray?,
    val metallicRoughnessTexture: ByteArray?,
    val baseColor: FloatArray?,
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
 * The single OpenGL ES 2.0 thread and context that every GlbView renders on,
 * plus the GPU model store.
 *
 * Sharing one context means a model is uploaded once and every view (and
 * every later visit to a screen) draws it without re-uploading, and the
 * shader is compiled once, in the background, when the plugin attaches.
 * Each view is just an EGL window surface on its own Flutter SurfaceTexture.
 *
 * Public methods may be called from any thread; GL work is queued to the GL
 * thread and image decoding runs on a small pool.
 */
internal class GlbGl {
    private val main = Handler(Looper.getMainLooper())
    private val tasks = LinkedBlockingQueue<Runnable>()
    private val decoder = Executors.newFixedThreadPool(
        Runtime.getRuntime().availableProcessors().minus(1).coerceIn(1, 4),
    ) { r -> Thread(r, "GlbView-decode").apply { priority = Thread.NORM_PRIORITY - 1 } }

    /** Views by texture id; created on the platform thread, drawn on GL. */
    private val views = ConcurrentHashMap<Long, ViewState>()

    @Volatile private var running = true
    @Volatile private var maxTextureSize = 4096
    @Volatile private var uintIndices = false
    /** Opens once GL capabilities (index type, max texture size) are known. */
    private val glReady = CountDownLatch(1)
    private val thread = Thread(::loop, "GlbView-GL").apply { start() }

    // GL-thread state.
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var config: EGLConfig? = null
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private lateinit var program: Program
    private var whiteTexture = 0
    private val models = HashMap<String, GpuModel>()

    private class GpuMesh(
        val vbo: Int,
        val ibo: Int,
        val indexCount: Int,
        /** GL_UNSIGNED_INT / GL_UNSIGNED_SHORT, or 0 for non-indexed. */
        val indexType: Int,
        val color: FloatArray,
        val texture: Int,
        val metallic: Float,
        val roughness: Float,
        val normalTexture: Int,
        val normalScale: Float,
        val mrTexture: Int,
        val clearcoat: Float,
    )

    private class GpuModel(val meshes: List<GpuMesh>) {
        var refs = 0
        /** Removed from the store; freed once no view draws it. */
        var dropped = false
    }

    private class GpuOverride(
        val texture: Int,
        val normalTexture: Int,
        val mrTexture: Int,
        val color: FloatArray?,
    )

    private class ViewState(
        val id: Long,
        val entry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        val width: Int,
        val height: Int,
        val autoRotate: Float,
        val logTimings: Boolean,
    ) {
        val createdNs = System.nanoTime()
        @Volatile var yaw = 0f
        @Volatile var pitch = 0f
        @Volatile var distance = 3.2f
        @Volatile var style = GlbStyle()
        @Volatile var dirty = true

        // GL thread only.
        var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        var model: GpuModel? = null
        var overrides: Map<Int, GpuOverride> = emptyMap()
        var angle = 0f
        var startNs = 0L
        var lastNs = 0L
        var firstFrameLogged = false
        val proj = FloatArray(16)
    }

    // -------------------------------------------------------------------
    // API (any thread)

    fun createView(
        entry: TextureRegistry.SurfaceTextureEntry,
        width: Int,
        height: Int,
        autoRotate: Float,
        logTimings: Boolean,
    ): Long {
        val surfaceTexture = entry.surfaceTexture()
        surfaceTexture.setDefaultBufferSize(width, height)
        val view = ViewState(entry.id(), entry, Surface(surfaceTexture), width, height, autoRotate, logTimings)
        views[view.id] = view
        post {
            val surface = EGL14.eglCreateWindowSurface(display, config, view.surface, intArrayOf(EGL14.EGL_NONE), 0)
            if (surface == EGL14.EGL_NO_SURFACE) {
                Log.e(TAG, "eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
                return@post
            }
            view.eglSurface = surface
            EGL14.eglMakeCurrent(display, surface, surface, context)
            // Never block the shared thread on one view's buffer queue.
            EGL14.eglSwapInterval(display, 0)
            Matrix.perspectiveM(view.proj, 0, FOV_DEGREES, width.toFloat() / height, NEAR, FAR)
            view.startNs = System.nanoTime()
            view.lastNs = view.startNs
        }
        return view.id
    }

    fun setCamera(id: Long, yaw: Float, pitch: Float, distance: Float) {
        val v = views[id] ?: return
        v.yaw = yaw
        v.pitch = pitch
        v.distance = distance
        v.dirty = true
    }

    fun setStyle(id: Long, style: GlbStyle) {
        val v = views[id] ?: return
        v.style = style
        v.dirty = true
    }

    /** Makes the view draw the cached model [key] (nothing if unknown). */
    fun setModel(id: Long, key: String, done: (String?) -> Unit) {
        post {
            val v = views[id]
            val m = models[key]
            if (v == null || m == null) {
                val error = if (v == null) "Unknown view" else "Model '$key' is not cached"
                main.post { done(error) }
                return@post
            }
            if (v.model !== m) {
                v.model?.let { release(it) }
                m.refs++
                v.model = m
            }
            v.dirty = true
            main.post { done(null) }
        }
    }

    fun disposeView(id: Long) {
        val v = views.remove(id) ?: return
        post {
            v.model?.let { release(it) }
            v.model = null
            deleteOverrides(v.overrides)
            v.overrides = emptyMap()
            if (v.eglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
                EGL14.eglDestroySurface(display, v.eglSurface)
                v.eglSurface = EGL14.EGL_NO_SURFACE
            }
            main.post {
                v.surface.release()
                v.entry.release()
            }
        }
    }

    /**
     * Uploads a model under [key], replacing any previous one. Images decode
     * in parallel off the GL thread; [done] runs on the main thread once
     * everything is on the GPU.
     */
    fun cacheModel(key: String, primitives: List<PrimitiveData>, logTimings: Boolean, done: (String?) -> Unit) {
        val start = System.nanoTime()
        val images = primitives.flatMap { listOf(it.texture, it.normalTexture, it.metallicRoughnessTexture) }
        decodeAll(images) { bitmaps, decodeNs ->
            // Vertex/index buffers are prepared here too, off the GL thread.
            val prepared = primitives.map { prepareGeometry(it) }
            // One GL task per texture so a big model doesn't stall views that
            // are already animating: the loop runs tasks within a per-frame
            // budget. Tasks run in order, so the last one sees all results.
            var glNs = 0L
            val textures = IntArray(bitmaps.size)
            val geometry = arrayOfNulls<Uploaded>(primitives.size)
            post {
                val t0 = System.nanoTime()
                prepared.forEachIndexed { i, g -> geometry[i] = uploadGeometry(g) }
                glNs += System.nanoTime() - t0
            }
            bitmaps.forEachIndexed { i, bitmap ->
                if (bitmap != null) post {
                    val t0 = System.nanoTime()
                    textures[i] = uploadTexture(bitmap)
                    glNs += System.nanoTime() - t0
                }
            }
            post {
                try {
                    val meshes = primitives.mapIndexed { i, p ->
                        val (vbo, ibo, count, type) = geometry[i]!!
                        GpuMesh(
                            vbo, ibo, count, type,
                            if (p.baseColor.size >= 4) p.baseColor.copyOf(4) else floatArrayOf(1f, 1f, 1f, 1f),
                            textures[i * 3], p.metallic, p.roughness,
                            textures[i * 3 + 1], p.normalScale,
                            textures[i * 3 + 2], p.clearcoat,
                        )
                    }
                    models.put(key, GpuModel(meshes))?.let { drop(it) }
                    if (logTimings) {
                        Log.d(TAG, "timing [$key]: decode ${ms(decodeNs)} ms (parallel wall), " +
                            "GL upload ${ms(glNs)} ms, total ${ms(System.nanoTime() - start)} ms")
                    }
                    main.post { done(null) }
                } catch (t: Throwable) {
                    Log.e(TAG, "Model upload failed", t)
                    main.post { done(t.message ?: t.toString()) }
                }
            }
        }
    }

    fun evictModel(key: String) {
        post { models.remove(key)?.let { drop(it) } }
    }

    /** Replaces the view's overrides; textures decode in parallel first. */
    fun setOverrides(id: Long, overrides: List<OverrideData>, done: (String?) -> Unit) {
        val images = overrides.flatMap { listOf(it.texture, it.normalTexture, it.metallicRoughnessTexture) }
        decodeAll(images) { bitmaps, _ ->
            post {
                val built = HashMap<Int, GpuOverride>()
                overrides.forEachIndexed { i, o ->
                    built[o.index] = GpuOverride(
                        uploadTexture(bitmaps[i * 3]),
                        uploadTexture(bitmaps[i * 3 + 1]),
                        uploadTexture(bitmaps[i * 3 + 2]),
                        o.baseColor?.takeIf { it.size >= 4 }?.copyOf(4),
                    )
                }
                val v = views[id]
                if (v == null) {
                    deleteOverrides(built)
                    main.post { done("Unknown view") }
                    return@post
                }
                deleteOverrides(v.overrides)
                v.overrides = built
                v.dirty = true
                main.post { done(null) }
            }
        }
    }

    /** Stops the GL thread and frees everything. Call on the platform thread. */
    fun shutdown() {
        if (!running) return
        running = false
        thread.interrupt()
        try {
            thread.join(1000)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        decoder.shutdownNow()
        for (v in views.values) {
            v.surface.release()
            v.entry.release()
        }
        views.clear()
    }

    // -------------------------------------------------------------------
    // GL thread

    private fun post(task: () -> Unit) {
        if (!running) return
        tasks.add(Runnable {
            // One failing task must not take down the thread every view uses.
            try {
                task()
            } catch (t: Throwable) {
                Log.e(TAG, "GL task failed", t)
            }
        })
    }

    private fun loop() {
        try {
            val initStart = System.nanoTime()
            initEgl()
            initGl()
            glReady.countDown()
            Log.d(TAG, "GL ready (EGL + shader compile ${ms(System.nanoTime() - initStart)} ms)")
            while (running) {
                val frameStart = System.nanoTime()
                // Uploads share the thread with rendering: run queued work up
                // to a budget, then draw, so visible views keep their frame rate.
                while (System.nanoTime() - frameStart < TASK_BUDGET_NS) {
                    val task = tasks.poll() ?: break
                    task.run()
                }
                for (v in views.values) renderView(v, frameStart)

                // Sleep until the next frame, waking early for new work.
                val waitNs = FRAME_NS - (System.nanoTime() - frameStart)
                if (waitNs > 0) tasks.poll(waitNs, TimeUnit.NANOSECONDS)?.run()
            }
        } catch (_: InterruptedException) {
            // shutdown()
        } catch (t: Throwable) {
            Log.e(TAG, "GL thread failed", t)
        } finally {
            glReady.countDown()
            releaseAll()
        }
    }

    private fun renderView(v: ViewState, now: Long) {
        if (v.eglSurface == EGL14.EGL_NO_SURFACE) return
        val dt = (now - v.lastNs) / 1e9f
        v.lastNs = now
        if (v.autoRotate != 0f) {
            v.angle = (v.angle + v.autoRotate * dt) % 360f
            v.dirty = true
        }
        if (v.style.animated) v.dirty = true
        if (!v.dirty) return
        v.dirty = false

        if (!EGL14.eglMakeCurrent(display, v.eglSurface, v.eglSurface, context)) return
        // Wrapped so float precision in the shader stays good.
        val time = ((now - v.startNs) / 1e9 % 1000.0).toFloat()
        draw(v, time)
        if (!EGL14.eglSwapBuffers(display, v.eglSurface)) {
            val error = EGL14.eglGetError()
            if (error == EGL14.EGL_BAD_SURFACE || error == EGL14.EGL_BAD_NATIVE_WINDOW) {
                Log.w(TAG, "Surface lost (0x${Integer.toHexString(error)})")
                EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
                EGL14.eglDestroySurface(display, v.eglSurface)
                v.eglSurface = EGL14.EGL_NO_SURFACE
            }
        } else if (v.logTimings && !v.firstFrameLogged && v.model != null) {
            v.firstFrameLogged = true
            Log.d(TAG, "timing: view ${v.id} first model frame ${ms(System.nanoTime() - v.createdNs)} ms after create")
        }
    }

    private val modelMatrix = FloatArray(16)
    private val rotX = FloatArray(16)
    private val rotY = FloatArray(16)
    private val viewMatrix = FloatArray(16)
    private val viewModel = FloatArray(16)
    private val mvp = FloatArray(16)

    private fun draw(v: ViewState, time: Float) {
        GLES20.glViewport(0, 0, v.width, v.height)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val model = v.model ?: return

        val d = v.distance
        Matrix.setLookAtM(viewMatrix, 0, 0f, 0f, d, 0f, 0f, 0f, 0f, 1f, 0f)
        Matrix.setRotateM(rotX, 0, v.pitch, 1f, 0f, 0f)
        Matrix.setRotateM(rotY, 0, v.yaw + v.angle, 0f, 1f, 0f)
        Matrix.multiplyMM(modelMatrix, 0, rotX, 0, rotY, 0)
        Matrix.multiplyMM(viewModel, 0, viewMatrix, 0, modelMatrix, 0)
        Matrix.multiplyMM(mvp, 0, v.proj, 0, viewModel, 0)

        val p = program
        GLES20.glUseProgram(p.id)
        GLES20.glUniformMatrix4fv(p.uMvp, 1, false, mvp, 0)
        GLES20.glUniformMatrix4fv(p.uModel, 1, false, modelMatrix, 0)
        GLES20.glUniform3f(p.uCameraPos, 0f, 0f, d)
        GLES20.glUniform1i(p.uTex, 0)
        GLES20.glUniform1i(p.uNormalTex, 1)
        GLES20.glUniform1i(p.uMrTex, 2)
        GLES20.glUniform1f(p.uTime, time)
        GLES20.glUniform2f(p.uResolution, v.width.toFloat(), v.height.toFloat())
        val st = v.style
        GLES20.glUniform1f(p.uGlossy, if (st.glossy) 1f else 0f)
        GLES20.glUniform1f(p.uGloss, st.gloss)
        GLES20.glUniform1f(p.uGlossOverride, if (st.glossOverridesMaterial) 1f else 0f)
        GLES20.glUniform3fv(p.uGradTop, 1, st.gradientTop, 0)
        GLES20.glUniform3fv(p.uGradBottom, 1, st.gradientBottom, 0)
        GLES20.glUniform1f(p.uGradMix, st.gradientMix)
        GLES20.glUniform1f(p.uSparkle, st.sparkle)
        GLES20.glUniform3fv(p.uSpecColor, 1, st.specularColor, 0)

        GLES20.glEnableVertexAttribArray(p.aPos)
        GLES20.glEnableVertexAttribArray(p.aNormal)
        GLES20.glEnableVertexAttribArray(p.aUv)
        GLES20.glEnableVertexAttribArray(p.aTangent)
        model.meshes.forEachIndexed { i, mesh ->
            val o = v.overrides[i]
            val texture = o?.texture?.takeIf { it != 0 } ?: mesh.texture
            val normalTexture = o?.normalTexture?.takeIf { it != 0 } ?: mesh.normalTexture
            val mrTexture = o?.mrTexture?.takeIf { it != 0 } ?: mesh.mrTexture
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, mesh.vbo)
            GLES20.glVertexAttribPointer(p.aPos, 3, GLES20.GL_FLOAT, false, STRIDE_BYTES, 0)
            GLES20.glVertexAttribPointer(p.aNormal, 3, GLES20.GL_FLOAT, false, STRIDE_BYTES, 12)
            GLES20.glVertexAttribPointer(p.aUv, 2, GLES20.GL_FLOAT, false, STRIDE_BYTES, 24)
            GLES20.glVertexAttribPointer(p.aTangent, 4, GLES20.GL_FLOAT, false, STRIDE_BYTES, 32)
            GLES20.glUniform4fv(p.uBaseColor, 1, o?.color ?: mesh.color, 0)
            GLES20.glUniform1f(p.uHasTex, if (texture != 0) 1f else 0f)
            GLES20.glUniform1f(p.uMetallic, mesh.metallic)
            GLES20.glUniform1f(p.uRoughness, mesh.roughness)
            GLES20.glUniform1f(p.uHasNormal, if (normalTexture != 0) 1f else 0f)
            GLES20.glUniform1f(p.uHasMr, if (mrTexture != 0) 1f else 0f)
            GLES20.glUniform1f(p.uNormalScale, mesh.normalScale)
            GLES20.glUniform1f(p.uClearcoat, mesh.clearcoat)
            bindTexture(0, texture)
            bindTexture(1, normalTexture)
            bindTexture(2, mrTexture)
            if (mesh.indexType != 0) {
                GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, mesh.ibo)
                GLES20.glDrawElements(GLES20.GL_TRIANGLES, mesh.indexCount, mesh.indexType, 0)
            } else {
                GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, mesh.indexCount)
            }
        }
        GLES20.glDisableVertexAttribArray(p.aPos)
        GLES20.glDisableVertexAttribArray(p.aNormal)
        GLES20.glDisableVertexAttribArray(p.aUv)
        GLES20.glDisableVertexAttribArray(p.aTangent)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0)
    }

    // -------------------------------------------------------------------
    // Setup / teardown (GL thread)

    private fun initEgl() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY) { "No EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }

        // Prefer 4x MSAA; fall back to a plain config if the driver has none.
        config = chooseConfig(samples = 4) ?: chooseConfig(samples = 0)
            ?: throw IllegalStateException("No suitable EGL config")
        context = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        // A tiny offscreen surface keeps the context current between views.
        pbuffer = EGL14.eglCreatePbufferSurface(
            display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        check(pbuffer != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed" }
        check(EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) { "eglMakeCurrent failed" }
    }

    private fun chooseConfig(samples: Int): EGLConfig? {
        val attribs = mutableListOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
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
        val ok = EGL14.eglChooseConfig(display, attribs.toIntArray(), 0, configs, 0, 1, count, 0)
        return if (ok && count[0] > 0) configs[0] else null
    }

    private fun initGl() {
        program = Program(linkProgram(GlbShaders.VERTEX_SHADER, GlbShaders.FRAGMENT_SHADER))
        uintIndices = GLES20.glGetString(GLES20.GL_EXTENSIONS)?.contains("GL_OES_element_index_uint") == true
        maxTextureSize = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, it, 0) }[0]

        whiteTexture = genTexture()
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, whiteTexture)
        val white = ByteBuffer.allocateDirect(4).put(byteArrayOf(-1, -1, -1, -1)).apply { position(0) }
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, 1, 1, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, white,
        )
        setSampling(powerOfTwo = false)

        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        GLES20.glDepthFunc(GLES20.GL_LEQUAL)
        GLES20.glDisable(GLES20.GL_CULL_FACE)
        GLES20.glFrontFace(GLES20.GL_CCW)
    }

    private fun releaseAll() {
        if (context == EGL14.EGL_NO_CONTEXT) return
        EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
        for (v in views.values) {
            deleteOverrides(v.overrides)
            if (v.eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, v.eglSurface)
            v.eglSurface = EGL14.EGL_NO_SURFACE
        }
        for (m in models.values) deleteModel(m)
        models.clear()
        if (whiteTexture != 0) GLES20.glDeleteTextures(1, intArrayOf(whiteTexture), 0)
        if (::program.isInitialized) GLES20.glDeleteProgram(program.id)
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, pbuffer)
        EGL14.eglDestroyContext(display, context)
        // No eglTerminate: the default display is shared with Flutter's own renderer.
        EGL14.eglReleaseThread()
        context = EGL14.EGL_NO_CONTEXT
    }

    // -------------------------------------------------------------------
    // Model store (GL thread)

    private fun release(m: GpuModel) {
        m.refs--
        if (m.refs <= 0 && m.dropped) deleteModel(m)
    }

    private fun drop(m: GpuModel) {
        m.dropped = true
        if (m.refs <= 0) deleteModel(m)
    }

    private fun deleteModel(m: GpuModel) {
        val buffers = m.meshes.flatMap { listOf(it.vbo, it.ibo) }.filter { it != 0 }.toIntArray()
        if (buffers.isNotEmpty()) GLES20.glDeleteBuffers(buffers.size, buffers, 0)
        val textures = m.meshes.flatMap { listOf(it.texture, it.normalTexture, it.mrTexture) }
            .filter { it != 0 }.toIntArray()
        if (textures.isNotEmpty()) GLES20.glDeleteTextures(textures.size, textures, 0)
    }

    private fun deleteOverrides(overrides: Map<Int, GpuOverride>) {
        val textures = overrides.values.flatMap { listOf(it.texture, it.normalTexture, it.mrTexture) }
            .filter { it != 0 }.toIntArray()
        if (textures.isNotEmpty()) GLES20.glDeleteTextures(textures.size, textures, 0)
    }

    // -------------------------------------------------------------------
    // Geometry

    /** Direct buffers built off the GL thread, in the index format the GPU supports. */
    private class PreparedGeometry(val vertices: Buffer, val vertexBytes: Int, val indices: Buffer?, val indexCount: Int, val indexType: Int)

    private data class Uploaded(val vbo: Int, val ibo: Int, val count: Int, val type: Int)

    private fun prepareGeometry(p: PrimitiveData): PreparedGeometry {
        val vertexCount = p.vertices.size / FLOATS_PER_VERTEX
        // The index format depends on a GL extension; only right after the
        // plugin attaches can this run before GL init.
        glReady.await(5, TimeUnit.SECONDS)
        return when {
            uintIndices || vertexCount <= 65536 -> {
                val vb = floatBuffer(p.vertices, vertexCount * FLOATS_PER_VERTEX)
                if (uintIndices) {
                    val ib = ByteBuffer.allocateDirect(p.indices.size * 4).order(ByteOrder.nativeOrder())
                        .asIntBuffer().put(p.indices).also { it.position(0) }
                    PreparedGeometry(vb, vertexCount * STRIDE_BYTES, ib, p.indices.size, GLES20.GL_UNSIGNED_INT)
                } else {
                    val sb = ByteBuffer.allocateDirect(p.indices.size * 2).order(ByteOrder.nativeOrder()).asShortBuffer()
                    for (i in p.indices) sb.put(i.toShort())
                    sb.position(0)
                    PreparedGeometry(vb, vertexCount * STRIDE_BYTES, sb, p.indices.size, GLES20.GL_UNSIGNED_SHORT)
                }
            }
            else -> {
                // No 32-bit indices and too many vertices for 16-bit: expand.
                val expanded = FloatArray(p.indices.size * FLOATS_PER_VERTEX)
                p.indices.forEachIndexed { i, v ->
                    System.arraycopy(p.vertices, v * FLOATS_PER_VERTEX, expanded, i * FLOATS_PER_VERTEX, FLOATS_PER_VERTEX)
                }
                PreparedGeometry(floatBuffer(expanded, expanded.size), expanded.size * 4, null, p.indices.size, 0)
            }
        }
    }

    private fun floatBuffer(data: FloatArray, length: Int): Buffer =
        ByteBuffer.allocateDirect(length * 4).order(ByteOrder.nativeOrder())
            .asFloatBuffer().put(data, 0, length).also { it.position(0) }

    private fun uploadGeometry(g: PreparedGeometry): Uploaded {
        val ids = IntArray(2)
        GLES20.glGenBuffers(if (g.indices != null) 2 else 1, ids, 0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, ids[0])
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, g.vertexBytes, g.vertices, GLES20.GL_STATIC_DRAW)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        if (g.indices != null) {
            val size = if (g.indexType == GLES20.GL_UNSIGNED_INT) 4 else 2
            GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, ids[1])
            GLES20.glBufferData(GLES20.GL_ELEMENT_ARRAY_BUFFER, g.indexCount * size, g.indices, GLES20.GL_STATIC_DRAW)
            GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0)
        }
        return Uploaded(ids[0], if (g.indices != null) ids[1] else 0, g.indexCount, g.indexType)
    }

    // -------------------------------------------------------------------
    // Textures

    /**
     * Decodes [images] in parallel on the decode pool; [then] runs on a pool
     * thread with bitmaps in the same order (null where absent or invalid).
     */
    private fun decodeAll(images: List<ByteArray?>, then: (List<Bitmap?>, Long) -> Unit) {
        val start = System.nanoTime()
        val out = arrayOfNulls<Bitmap>(images.size)
        val jobs = images.withIndex().filter { it.value != null }
        if (jobs.isEmpty()) {
            decoder.execute { then(out.toList(), 0) }
            return
        }
        val remaining = AtomicInteger(jobs.size)
        for ((i, bytes) in jobs) {
            decoder.execute {
                out[i] = try {
                    decodeBitmap(bytes!!)
                } catch (t: Throwable) {
                    Log.w(TAG, "Could not decode texture image", t)
                    null
                }
                if (remaining.decrementAndGet() == 0) then(out.toList(), System.nanoTime() - start)
            }
        }
    }

    private fun decodeBitmap(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            Log.w(TAG, "Could not decode texture image")
            return null
        }
        var sample = 1
        val max = maxTextureSize
        while (bounds.outWidth / sample > max || bounds.outHeight / sample > max) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inPremultiplied = false
            inScaled = false
        })
    }

    /** Uploads and recycles [bitmap]; 0 if null. */
    private fun uploadTexture(bitmap: Bitmap?): Int {
        if (bitmap == null) return 0
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

    // -------------------------------------------------------------------
    // Shaders

    private class Program(val id: Int) {
        val aPos = GLES20.glGetAttribLocation(id, "aPos")
        val aNormal = GLES20.glGetAttribLocation(id, "aNormal")
        val aUv = GLES20.glGetAttribLocation(id, "aUv")
        val aTangent = GLES20.glGetAttribLocation(id, "aTangent")
        val uMvp = GLES20.glGetUniformLocation(id, "uMvp")
        val uModel = GLES20.glGetUniformLocation(id, "uModel")
        val uBaseColor = GLES20.glGetUniformLocation(id, "uBaseColor")
        val uCameraPos = GLES20.glGetUniformLocation(id, "uCameraPos")
        val uTex = GLES20.glGetUniformLocation(id, "uTex")
        val uNormalTex = GLES20.glGetUniformLocation(id, "uNormalTex")
        val uMrTex = GLES20.glGetUniformLocation(id, "uMrTex")
        val uHasTex = GLES20.glGetUniformLocation(id, "uHasTex")
        val uHasNormal = GLES20.glGetUniformLocation(id, "uHasNormal")
        val uHasMr = GLES20.glGetUniformLocation(id, "uHasMr")
        val uNormalScale = GLES20.glGetUniformLocation(id, "uNormalScale")
        val uClearcoat = GLES20.glGetUniformLocation(id, "uClearcoat")
        val uTime = GLES20.glGetUniformLocation(id, "uTime")
        val uResolution = GLES20.glGetUniformLocation(id, "uResolution")
        val uMetallic = GLES20.glGetUniformLocation(id, "uMetallic")
        val uRoughness = GLES20.glGetUniformLocation(id, "uRoughness")
        val uGlossy = GLES20.glGetUniformLocation(id, "uGlossy")
        val uGloss = GLES20.glGetUniformLocation(id, "uGloss")
        val uGlossOverride = GLES20.glGetUniformLocation(id, "uGlossOverride")
        val uGradTop = GLES20.glGetUniformLocation(id, "uGradTop")
        val uGradBottom = GLES20.glGetUniformLocation(id, "uGradBottom")
        val uGradMix = GLES20.glGetUniformLocation(id, "uGradMix")
        val uSparkle = GLES20.glGetUniformLocation(id, "uSparkle")
        val uSpecColor = GLES20.glGetUniformLocation(id, "uSpecColor")
    }

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

    private fun ms(ns: Long) = "%.1f".format(ns / 1e6)

    private companion object {
        const val TAG = "GlbView"
        const val FRAME_NS = 16_666_667L
        const val TASK_BUDGET_NS = 8_000_000L
        const val FLOATS_PER_VERTEX = 12
        const val STRIDE_BYTES = FLOATS_PER_VERTEX * 4
        const val FOV_DEGREES = 40f
        const val NEAR = 0.1f
        const val FAR = 100f
    }
}
