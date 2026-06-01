#include <metal_stdlib>
using namespace metal;

// M0 stereo debug pattern. It is intentionally loud so hardware validation can
// distinguish "nothing rendered" from "remote scene opened".
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

    float3 base = in.eyeIndex == 0
        ? float3(1.0, 0.12, 0.04)
        : float3(0.04, 0.28, 1.0);
    float3 accent = in.eyeIndex == 0
        ? float3(1.0, 0.85, 0.10)
        : float3(0.10, 1.0, 0.95);

    float intensity = 0.25 + 0.45 * rings + 0.35 * sweep + 0.25 * grid;
    return float4(mix(base, accent, clamp(intensity, 0.0, 1.0)), 1.0);
}

// Fullscreen pass used to present Minecraft's already-projected per-eye frames.
// Each eye texture is rendered by the game with its own projection matrix, so the
// correct presentation is a 1:1 fullscreen blit into the eye's viewport - NOT a
// world-anchored quad. We emit a single oversized triangle covering NDC and let
// vertex amplification fan it out to both eye viewports.
//
// Depth: the compositor requires a written depth value to display content in an
// immersive space. The depth attachment clears to 0 with compareFunction .always
// and depth-write enabled, so we emit a constant mid-range NDC depth (0.5). Because
// Minecraft bakes the head pose into each frame, presenting head-locked fullscreen
// is correct and stable.
vertex VertexOut fullscreen_vertex(
    uint vid [[vertex_id]],
    uint ampId [[amplification_id]]
) {
    // Oversized triangle: covers the full [-1, 1] NDC range with 3 vertices.
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 p = positions[vid % 3];

    VertexOut out;
    out.position = float4(p, 0.5, 1.0);
    // uv maps NDC -> [0,1]; matches the panel's y-up -> v-up relationship so the
    // (double-flipped GL->Metal) image stays upright, exactly as seen in testing.
    out.uv = p * 0.5 + 0.5;
    out.eyeIndex = ampId;
    return out;
}

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
