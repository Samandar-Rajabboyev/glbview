package dev.samandar.glbview

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/** Hosts native GLB renderers, one per Flutter texture. */
class GlbViewPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var textures: TextureRegistry? = null
    private val renderers = HashMap<Long, GlbRenderer>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "dev.samandar/glbview").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        renderers.values.forEach { it.dispose() }
        renderers.clear()
        textures = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> create(call, result)
                "loadModel" -> loadModel(call, result)
                "setCamera" -> {
                    val renderer = rendererFor(call, result) ?: return
                    renderer.setCamera(
                        call.number("yaw").toFloat(),
                        call.number("pitch").toFloat(),
                        call.number("distance").toFloat(),
                    )
                    result.success(null)
                }
                "setStyle" -> {
                    val renderer = rendererFor(call, result) ?: return
                    renderer.setStyle(
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
                    renderers.remove(call.id())?.dispose()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("glbview_error", e.message ?: e.toString(), null)
        }
    }

    private fun create(call: MethodCall, result: MethodChannel.Result) {
        val registry = textures
        if (registry == null) {
            result.error("no_engine", "Plugin is not attached to an engine", null)
            return
        }
        val width = call.number("width").toInt().coerceAtLeast(1)
        val height = call.number("height").toInt().coerceAtLeast(1)
        val autoRotate = call.number("autoRotate").toFloat()
        @Suppress("DEPRECATION")
        val entry = registry.createSurfaceTexture()
        val renderer = GlbRenderer(entry, width, height, autoRotate)
        renderers[entry.id()] = renderer
        result.success(entry.id())
    }

    private fun loadModel(call: MethodCall, result: MethodChannel.Result) {
        val renderer = rendererFor(call, result) ?: return
        val raw = call.argument<List<*>>("primitives")
            ?: throw IllegalArgumentException("Missing primitives")
        val primitives = raw.map { item ->
            val map = item as? Map<*, *> ?: throw IllegalArgumentException("Bad primitive")
            val vertices = map["vertices"] as? FloatArray
                ?: throw IllegalArgumentException("Primitive without vertices")
            val color = map["baseColor"] as? FloatArray ?: floatArrayOf(1f, 1f, 1f, 1f)
            PrimitiveData(
                vertices,
                color,
                map["texture"] as? ByteArray,
                (map["metallic"] as? Number)?.toFloat() ?: 0f,
                (map["roughness"] as? Number)?.toFloat() ?: 0.5f,
                map["normalTexture"] as? ByteArray,
                (map["normalScale"] as? Number)?.toFloat() ?: 1f,
                map["metallicRoughnessTexture"] as? ByteArray,
                (map["clearcoat"] as? Number)?.toFloat() ?: 0f,
            )
        }
        renderer.loadModel(primitives)
        result.success(null)
    }

    private fun rendererFor(call: MethodCall, result: MethodChannel.Result): GlbRenderer? {
        val renderer = renderers[call.id()]
        if (renderer == null) result.error("no_texture", "Unknown texture id", null)
        return renderer
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
