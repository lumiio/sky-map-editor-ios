#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut vsGradient(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VSOut out;
    out.position = float4(p[vid], 0.0, 1.0);
    out.uv = p[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 fsGradient(VSOut in [[stage_in]]) {
    float3 top = float3(0.05, 0.09, 0.20);
    float3 bottom = float3(0.35, 0.52, 0.75);
    return float4(mix(bottom, top, saturate(in.uv.y)), 1.0);
}
