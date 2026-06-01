#include <metal_stdlib>
using namespace metal;

// Debug stereo pattern (Phase 1: immersive opened, no host video yet). Intentionally loud so
// "stage opened but no video" is visually distinct from a black/failed stage. Mirrors the macOS
// host's M0 pattern: orange/yellow left eye, blue/cyan right eye.
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

// Fullscreen pass for presenting the decoded game frame. A single oversized triangle covers NDC;
// vertex amplification fans it out to both eye viewports. Depth is written constant (the
// compositor requires a written depth value; reprojection handles head-lock).
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

// Samples one decoded, stereo-packed video frame into the per-eye viewport.
//   packing == 0  side-by-side: left eye → u∈[0,0.5), right eye → u∈[0.5,1]
//   packing == 1  top-bottom:   left eye → v∈[0,0.5), right eye → v∈[0.5,1]
//
// The decoded texture is top-left origin (VideoToolbox/Metal). `fullscreen_vertex` maps NDC-top
// → uv.y = 1, so we flip v (`1 - uv.y`) to sample texture row 0 at the top of the view. If the
// image ever appears vertically inverted on-device, this single flip is the knob to toggle.
fragment float4 companion_external_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> frame [[texture(0)]],
    sampler textureSampler [[sampler(0)]],
    constant uint &packing [[buffer(0)]]
) {
    float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
    float vFlipped = 1.0 - uv.y;
    float2 sampleUV;
    if (packing == 0) {
        float u = uv.x * 0.5 + (in.eyeIndex == 0 ? 0.0 : 0.5);
        sampleUV = float2(u, vFlipped);
    } else {
        float v = vFlipped * 0.5 + (in.eyeIndex == 0 ? 0.0 : 0.5);
        sampleUV = float2(uv.x, v);
    }
    float4 color = frame.sample(textureSampler, sampleUV);
    color.a = 1.0;
    return color;
}
