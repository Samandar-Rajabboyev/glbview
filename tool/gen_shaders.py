#!/usr/bin/env python3
"""Generates the GLSL (Android) and MSL (iOS) shaders from one source.

The shading math is written once below in GLSL-flavoured code and translated
mechanically to Metal, so both platforms stay identical. The results are
written between the GENERATED SHADERS markers in

  android/src/main/kotlin/dev/samandar/glbview/GlbRenderer.kt
  ios/glbview/Sources/glbview/GlbRenderer.swift

Usage: python3 tool/gen_shaders.py   (from the plugin root)
"""
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
KOTLIN = os.path.join(ROOT, "android/src/main/kotlin/dev/samandar/glbview/GlbRenderer.kt")
SWIFT = os.path.join(ROOT, "ios/glbview/Sources/glbview/GlbRenderer.swift")

# Shared helper functions. Only built-ins common to GLSL ES 1.00 and MSL; no
# loops, no derivatives.
FUNCTIONS = """
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
"""

# Fragment body. Inputs are provided by each platform's preamble under these
# names; textures are read through sampleBase/sampleNormal/sampleMr.
BODY = """
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
"""

GLSL_VERTEX = """
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

GLSL_FRAGMENT_HEAD = """
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
"""

GLSL_MAIN_HEAD = """
void main() {
    bool frontFacing = gl_FrontFacing;
    vec2 fragCoord = gl_FragCoord.xy;
"""

GLSL_MAIN_TAIL = """
    gl_FragColor = vec4(outColor, 1.0);
}
"""

MSL_HEAD = """
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
"""

MSL_MAIN_HEAD = """
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
"""

MSL_MAIN_TAIL = """
    return float4(outColor, 1.0);
}
"""


def to_msl(code):
    code = re.sub(r"\bvec([234])\b", r"float\1", code)
    code = code.replace("const float", "constant float")
    code = code.replace("inout float3 spec", "thread float3 &spec")
    # Free functions get internal linkage.
    code = re.sub(r"^(float\d?|bool) (\w+)\(", r"static \1 \2(", code, flags=re.M)
    return code


def indent(text, prefix):
    return "\n".join(prefix + line if line.strip() else "" for line in text.strip("\n").split("\n"))


def replace_block(path, block):
    with open(path) as f:
        src = f.read()
    begin = src.index("// BEGIN GENERATED SHADERS")
    end = src.index("// END GENERATED SHADERS")
    begin = src.index("\n", begin) + 1
    end = src.rindex("\n", 0, end) + 1
    with open(path, "w") as f:
        f.write(src[:begin] + block + src[end:])


def main():
    glsl_fragment = GLSL_FRAGMENT_HEAD + FUNCTIONS + GLSL_MAIN_HEAD + BODY + GLSL_MAIN_TAIL
    msl = MSL_HEAD + to_msl(FUNCTIONS) + MSL_MAIN_HEAD + to_msl(BODY) + MSL_MAIN_TAIL
    for text in (glsl_fragment, GLSL_VERTEX, msl):
        assert "$" not in text and '"""' not in text and "\\" not in text

    kotlin = (
        '        const val VERTEX_SHADER = """\n'
        + GLSL_VERTEX.strip("\n") + '\n"""\n\n'
        + '        const val FRAGMENT_SHADER = """\n'
        + glsl_fragment.strip("\n") + '\n"""\n'
    )
    replace_block(KOTLIN, kotlin)

    swift = '  private static let shaderSource = """\n' + indent(msl, "    ") + '\n    """\n'
    replace_block(SWIFT, swift)
    print("updated", os.path.relpath(KOTLIN, ROOT), "and", os.path.relpath(SWIFT, ROOT))


if __name__ == "__main__":
    main()
