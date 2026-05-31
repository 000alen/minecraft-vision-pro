#include <metal_stdlib>
using namespace metal;

// M0 stereo debug cube — expand after Compositor Services validation on device.
struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut composite_vertex(uint vid [[vertex_id]]) {
    VertexOut out;
    // Placeholder triangle for pipeline compile check
    float2 positions[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    out.position = float4(positions[vid % 3], 0.0, 1.0);
    out.color = float3(0.2, 0.6, 1.0);
    return out;
}

fragment float4 composite_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
