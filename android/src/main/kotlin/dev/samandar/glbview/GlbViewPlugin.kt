package dev.samandar.glbview

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/** Bridges the method channel to the shared [GlbGl] renderer. */
class GlbViewPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var textures: TextureRegistry? = null
    private var gl: GlbGl? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures = binding.textureRegistry
        // Starts the GL thread now so the shader is compiled before any view.
        gl = GlbGl()
        channel = MethodChannel(binding.binaryMessenger, "dev.samandar/glbview").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        gl?.shutdown()
        gl = null
        textures = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val gl = gl
        if (gl == null) {
            result.error("no_engine", "Plugin is not attached to an engine", null)
            return
        }
        try {
            when (call.method) {
                "create" -> {
                    val registry = textures ?: throw IllegalStateException("No texture registry")
                    @Suppress("DEPRECATION")
                    val entry = registry.createSurfaceTexture()
                    val id = gl.createView(
                        entry,
                        call.number("width").toInt().coerceAtLeast(1),
                        call.number("height").toInt().coerceAtLeast(1),
                        call.number("autoRotate").toFloat(),
                        call.argument<Boolean>("debugTimings") ?: false,
                    )
                    result.success(id)
                }
                "cacheModel" -> {
                    val key = call.argument<String>("key") ?: throw IllegalArgumentException("Missing key")
                    val raw = call.argument<List<*>>("primitives")
                        ?: throw IllegalArgumentException("Missing primitives")
                    val primitives = raw.map { item ->
                        val map = item as? Map<*, *> ?: throw IllegalArgumentException("Bad primitive")
                        PrimitiveData(
                            map["vertices"] as? FloatArray ?: throw IllegalArgumentException("No vertices"),
                            map["indices"] as? IntArray ?: throw IllegalArgumentException("No indices"),
                            map["baseColor"] as? FloatArray ?: floatArrayOf(1f, 1f, 1f, 1f),
                            map["texture"] as? ByteArray,
                            (map["metallic"] as? Number)?.toFloat() ?: 0f,
                            (map["roughness"] as? Number)?.toFloat() ?: 0.5f,
                            map["normalTexture"] as? ByteArray,
                            (map["normalScale"] as? Number)?.toFloat() ?: 1f,
                            map["metallicRoughnessTexture"] as? ByteArray,
                            (map["clearcoat"] as? Number)?.toFloat() ?: 0f,
                        )
                    }
                    gl.cacheModel(key, primitives, call.argument<Boolean>("debugTimings") ?: false) {
                        reply(result, it)
                    }
                }
                "evictModel" -> {
                    gl.evictModel(call.argument<String>("key") ?: throw IllegalArgumentException("Missing key"))
                    result.success(null)
                }
                "setModel" -> {
                    val key = call.argument<String>("key") ?: throw IllegalArgumentException("Missing key")
                    gl.setModel(call.id(), key) { reply(result, it) }
                }
                "setOverrides" -> {
                    val raw = call.argument<List<*>>("overrides") ?: emptyList<Any>()
                    val overrides = raw.map { item ->
                        val map = item as? Map<*, *> ?: throw IllegalArgumentException("Bad override")
                        OverrideData(
                            (map["index"] as? Number)?.toInt() ?: throw IllegalArgumentException("No index"),
                            map["texture"] as? ByteArray,
                            map["normalTexture"] as? ByteArray,
                            map["metallicRoughnessTexture"] as? ByteArray,
                            map["baseColor"] as? FloatArray,
                        )
                    }
                    gl.setOverrides(call.id(), overrides) { reply(result, it) }
                }
                "setCamera" -> {
                    gl.setCamera(
                        call.id(),
                        call.number("yaw").toFloat(),
                        call.number("pitch").toFloat(),
                        call.number("distance").toFloat(),
                    )
                    result.success(null)
                }
                "setStyle" -> {
                    gl.setStyle(
                        call.id(),
                        GlbStyle(
                            glossy = call.argument<Boolean>("glossy") ?: true,
                            gloss = call.number("gloss").toFloat(),
                            glossOverridesMaterial = call.argument<Boolean>("glossOverridesMaterial") ?: true,
                            gradientTop = call.rgb("gradientTop"),
                            gradientBottom = call.rgb("gradientBottom"),
                            gradientMix = call.number("gradientMix").toFloat(),
                            sparkle = call.number("sparkle").toFloat(),
                            specularColor = call.rgb("specularColor"),
                        ),
                    )
                    result.success(null)
                }
                "dispose" -> {
                    gl.disposeView(call.id())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("glbview_error", e.message ?: e.toString(), null)
        }
    }

    private fun reply(result: MethodChannel.Result, error: String?) {
        if (error == null) result.success(null) else result.error("glbview_error", error, null)
    }

    /** ARGB int -> sRGB components 0..1 (alpha ignored). */
    private fun MethodCall.rgb(key: String): FloatArray {
        val argb = number(key).toLong().toInt()
        return floatArrayOf(
            ((argb shr 16) and 0xFF) / 255f,
            ((argb shr 8) and 0xFF) / 255f,
            (argb and 0xFF) / 255f,
        )
    }

    private fun MethodCall.id(): Long = number("id").toLong()

    private fun MethodCall.number(key: String): Number =
        argument<Number>(key) ?: throw IllegalArgumentException("Missing '$key'")
}
