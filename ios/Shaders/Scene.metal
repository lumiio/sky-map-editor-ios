#include <metal_stdlib>
using namespace metal;

struct SkyOut {
    float4 position [[position]];
    float2 uv;
};

vertex SkyOut vsSky(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    SkyOut out;
    out.position = float4(p[vid], 0.999, 1.0);
    out.uv = p[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 fsSky(SkyOut in [[stage_in]]) {
    float3 zenith = float3(0.10, 0.20, 0.40);
    float3 horizon = float3(0.62, 0.72, 0.82);
    float3 ground = float3(0.16, 0.17, 0.18);
    float t = in.uv.y;
    float3 color = t > 0.5 ? mix(horizon, zenith, saturate((t - 0.5) * 2.0))
                           : mix(ground, horizon, saturate(t * 2.0));
    return float4(color, 1.0);
}

struct TerrainIn {
    float3 position  [[attribute(0)]];
    float4 normal    [[attribute(1)]];
    float4 material0 [[attribute(2)]];
    float4 material1 [[attribute(3)]];
};

struct TerrainOut {
    float4 position [[position]];
    float3 normal;
    float4 material0;
    float4 material1;
};

vertex TerrainOut vsTerrain(TerrainIn in [[stage_in]],
                            constant float4x4 &viewProj [[buffer(1)]]) {
    TerrainOut out;
    out.position = viewProj * float4(in.position, 1.0);
    out.normal = in.normal.xyz;
    out.material0 = in.material0;
    out.material1 = in.material1;
    return out;
}

// 编辑器视口 basic 着色：0.55 + 0.45 * |n.y| / |n|，颜色取材质表；
// 叠加层用 a_material0*256 与材质 id 比对，权重求和当 alpha。
struct TerrainParams {
    uint materialId;
    uint alphaMode;
};

fragment float4 fsTerrain(TerrainOut in [[stage_in]],
                          constant float4 &color [[buffer(0)]],
                          constant TerrainParams &params [[buffer(1)]]) {
    float alpha = 1.0;
    if (params.alphaMode == 1u) {
        int4 ids = int4(trunc(in.material0 * 256.0));
        int mid = int(params.materialId);
        alpha = 0.0;
        if (ids.x == mid) { alpha += in.material1.x; }
        if (ids.y == mid) { alpha += in.material1.y; }
        if (ids.z == mid) { alpha += in.material1.z; }
        if (ids.w == mid) { alpha += in.material1.w; }
        if (alpha <= 0.0) { discard_fragment(); }
    }
    float normalLength = max(length(in.normal), 0.00001);
    float lighting = 0.55 + 0.45 * abs(in.normal.y) / normalLength;
    return float4(color.rgb * lighting, alpha);
}

struct ModelIn {
    float3 position [[attribute(0)]];
    float4 normal   [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct ModelOut {
    float4 position [[position]];
    float3 normal;
    float4 color;
};

vertex ModelOut vsModel(ModelIn in [[stage_in]],
                        constant float4x4 &viewProj [[buffer(1)]]) {
    ModelOut out;
    out.position = viewProj * float4(in.position, 1.0);
    out.normal = in.normal.xyz;
    out.color = in.color;
    return out;
}

fragment float4 fsModel(ModelOut in [[stage_in]],
                        constant float4 &color [[buffer(0)]]) {
    float normalLength = max(length(in.normal), 0.00001);
    float lighting = 0.55 + 0.45 * abs(in.normal.y) / normalLength;
    float3 tint = color.rgb * in.color.rgb * lighting;
    float alpha = color.a * in.color.a;
    if (alpha <= 0.0) { discard_fragment(); }
    return float4(tint, alpha);
}
