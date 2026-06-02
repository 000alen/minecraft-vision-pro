#include <metal_stdlib>
using namespace metal;

// Shared Metal library for both VisionCraft targets, compiled into each app's default library via
// XcodeGen (`sources: ../shared/Shaders`). The debug pattern + fullscreen vertex are identical on
// host and companion; the two external fragments cover the two presentation paths:
//   - companion_external_fragment : decode-and-reproject the streamed YUV frame (network path)
//   - external_frame_fragment     : 1:1 blit of two RGBA eye textures (Mac-local immersive path)
// Each target only references the entry points it needs; unused functions are dead-stripped.

// Debug stereo pattern (immersive opened, no host video yet). Intentionally loud so "stage opened
// but no video" is visually distinct from a black/failed stage: orange/yellow left, blue/cyan right.
struct DebugUniforms {
    float4x4 mvpLeft;
    float4x4 mvpRight;
    float time;
    uint eyeIndex;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    uint eyeIndex;
};

vertex VertexOut composite_vertex(
    uint vid [[vertex_id]],
    uint ampId [[amplification_id]],
    constant DebugUniforms &uniforms [[buffer(0)]]
) {
    VertexOut out;
    float3 positions[6] = {
        float3(-0.35, -0.35, 0.0), float3(0.35, -0.35, 0.0), float3(-0.35, 0.35, 0.0),
        float3(0.35, -0.35, 0.0), float3(0.35, 0.35, 0.0), float3(-0.35, 0.35, 0.0)
    };
    float3 p = positions[vid % 6];
    uint eyeIndex = uniforms.eyeIndex + ampId;
    float4x4 mvp = eyeIndex == 0 ? uniforms.mvpLeft : uniforms.mvpRight;
    out.position = mvp * float4(p, 1.0);
    out.uv = p.xy / 0.7 + 0.5;
    out.eyeIndex = eyeIndex;
    return out;
}

fragment float4 composite_fragment(
    VertexOut in [[stage_in]],
    constant DebugUniforms &uniforms [[buffer(0)]]
) {
    float2 centered = in.uv - float2(0.5, 0.5);
    float radius = length(centered);
    float rings = smoothstep(0.025, 0.0, abs(fract(radius * 10.0 - uniforms.time * 0.8) - 0.5));
    float sweep = smoothstep(0.04, 0.0, abs(fract(in.uv.x + uniforms.time * 0.25) - 0.5));
    float grid = step(0.965, max(fract(in.uv.x * 8.0), fract(in.uv.y * 8.0)));

    float3 base = in.eyeIndex == 0 ? float3(1.0, 0.12, 0.04) : float3(0.04, 0.28, 1.0);
    float3 accent = in.eyeIndex == 0 ? float3(1.0, 0.85, 0.10) : float3(0.10, 1.0, 0.95);

    float intensity = 0.25 + 0.45 * rings + 0.35 * sweep + 0.25 * grid;
    return float4(mix(base, accent, clamp(intensity, 0.0, 1.0)), 1.0);
}

// Fullscreen pass for presenting an already-projected per-eye frame. A single oversized triangle
// covers NDC; vertex amplification fans it out to both eye viewports. Depth is written constant (the
// compositor requires a written depth value; reprojection / pre-baked head pose handles head-lock).
vertex VertexOut fullscreen_vertex(
    uint vid [[vertex_id]],
    uint ampId [[amplification_id]]
) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 p = positions[vid % 3];
    VertexOut out;
    out.position = float4(p, 0.5, 1.0);
    out.uv = p * 0.5 + 0.5;
    out.eyeIndex = ampId;
    return out;
}

// Composite parameters (mirrors `CompositeUniforms` in CompanionRenderer.swift, same field
// order/layout).
//  - tangents*: positive frustum tangents [left, right, up, down] per eye, used to map a
//    display-pixel NDC ↔ a view-space ray for rotational reprojection.
//  - warp: delta rotation R_render⁻¹·R_now applied to the current display ray to find the
//    render-time ray. Identity (and `reproject == 0`) when the render orientation is unknown.
//  - packing: 0 side-by-side, 1 top-bottom.
struct CompositeUniforms {
    float4 tangentsLeft;
    float4 tangentsRight;
    float4x4 warp;
    uint packing;
    uint reproject;
};

// Rotational async timewarp: given this display pixel's eye-space ray, rotate it by `warp` into the
// orientation the frame was rendered with, then reproject through the (identical) frustum to find
// the source UV. Returns false when the rotated ray leaves the rendered frustum (show black).
static bool reprojectUV(float2 uv, float4 tangents, float4x4 warp, thread float2 &outUV) {
    float l = tangents.x, r = tangents.y, up = tangents.z, dn = tangents.w;
    // Display-pixel ray in eye space (+x right, +y up, −z forward).
    float tx = mix(-l, r, uv.x);
    float ty = mix(-dn, up, uv.y);
    float3 dNow = normalize(float3(tx, ty, -1.0));
    float3 dRender = (warp * float4(dNow, 0.0)).xyz;
    if (dRender.z >= -1e-4) { return false; } // behind the eye → outside the rendered view
    float txr = dRender.x / (-dRender.z);
    float tyr = dRender.y / (-dRender.z);
    float ru = (txr + l) / (l + r);
    float rv = (tyr + dn) / (up + dn);
    if (ru < 0.0 || ru > 1.0 || rv < 0.0 || rv > 1.0) { return false; }
    outUV = float2(ru, rv);
    return true;
}

// Companion network path: sample one decoded, stereo-packed video frame into the per-eye viewport,
// converting biplanar full-range BT.709 YCbCr → RGB.
//   packing == 0  side-by-side: left eye → u∈[0,0.5), right eye → u∈[0.5,1]
//   packing == 1  top-bottom:   left eye → v∈[0,0.5), right eye → v∈[0.5,1]
//
// Orientation: the encoded stereo frame originates from Minecraft's OpenGL eye textures, which the
// Mac host packs WITHOUT a vertical flip, so the decoded plane's last row is the image top. Our
// `fullscreen_vertex` maps screen-top → uv.y = 1; sampling `v = uv.y` therefore reads the image top
// at the screen top — exactly the zero-flip invariant the ALVR visionOS client relies on
// (`videoFrameVertexShaderCommon`, `texCoord.y = uv.y`). If the image ever appears vertically
// inverted, this `v` mapping (and the Mac encoder's row order) is the single knob.
fragment float4 companion_external_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> lumaTex [[texture(0)]],
    texture2d<float> chromaTex [[texture(1)]],
    sampler textureSampler [[sampler(0)]],
    constant CompositeUniforms &u [[buffer(0)]]
) {
    float2 uv = clamp(in.uv, float2(0.0), float2(1.0));

    // Reproject the eye ray to the rendered orientation. When disabled or the rotated ray reduces
    // to identity, this returns the same uv (the warp is a mathematical no-op for zero rotation).
    if (u.reproject != 0) {
        float4 tangents = in.eyeIndex == 0 ? u.tangentsLeft : u.tangentsRight;
        float2 warped;
        if (reprojectUV(uv, tangents, u.warp, warped)) {
            uv = warped;
        } else {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float sampleV = uv.y;
    float2 sampleUV;
    if (u.packing == 0) {
        float halfU = uv.x * 0.5 + (in.eyeIndex == 0 ? 0.0 : 0.5);
        sampleUV = float2(halfU, sampleV);
    } else {
        float halfV = sampleV * 0.5 + (in.eyeIndex == 0 ? 0.0 : 0.5);
        sampleUV = float2(uv.x, halfV);
    }

    // Full-range BT.709 YCbCr → RGB. Y is full-range (decoder requested full range); chroma is
    // centered at 0.5. Output is gamma-encoded, matching the source frame and the non-sRGB color
    // attachment (no extra EOTF).
    float Y = lumaTex.sample(textureSampler, sampleUV).r;
    float2 cbcr = chromaTex.sample(textureSampler, sampleUV).rg - float2(0.5, 0.5);
    float3 rgb;
    rgb.r = Y + 1.5748 * cbcr.y;
    rgb.g = Y - 0.1873 * cbcr.x - 0.4681 * cbcr.y;
    rgb.b = Y + 1.8556 * cbcr.x;
    return float4(saturate(rgb), 1.0);
}

// Mac-local immersive path: present Minecraft's already-projected per-eye RGBA textures with a 1:1
// fullscreen blit into each eye's viewport (the game bakes its own projection + head pose).
fragment float4 external_frame_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> leftEye [[texture(0)]],
    texture2d<float> rightEye [[texture(1)]],
    sampler textureSampler [[sampler(0)]]
) {
    float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
    float4 color = in.eyeIndex == 0
        ? leftEye.sample(textureSampler, uv)
        : rightEye.sample(textureSampler, uv);
    color.a = 1.0;
    return color;
}
