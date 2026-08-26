#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// 頂點着色器：保持 16:9 比例
// flip=1 時垂直翻轉（PiP 用，因為 AVSampleBufferDisplayLayer 是左上原點）
vertex VertexOut vertexPassthrough(uint vertexID [[vertex_id]],
                                   constant float2 &viewSize [[buffer(0)]],
                                   constant uint &flip [[buffer(1)]]) {
    VertexOut out;

    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    float2 tc = texCoords[vertexID];
    float posY = positions[vertexID].y;

    if (flip != 0) {
        tc.y = 1.0 - tc.y;
        posY = -posY;
    }

    // 固定目標比例 16:9
    float targetAspect = 16.0 / 9.0;
    float viewAspect = viewSize.x / viewSize.y;

    float scaleX = (viewAspect > targetAspect) ? targetAspect / viewAspect : 1.0;
    float scaleY = (viewAspect < targetAspect) ? viewAspect / targetAspect : 1.0;

    out.position = float4(positions[vertexID].x * scaleX,
                          posY * scaleY,
                          0.0, 1.0);
    out.texCoord = tc;
    return out;
}

// 片段着色器：NV12 → RGB + 左上角文字 overlay
fragment float4 fragmentNV12(VertexOut in [[stage_in]],
                             texture2d<float, access::sample> texY [[texture(0)]],
                             texture2d<float, access::sample> texUV [[texture(1)]],
                             texture2d<float, access::sample> textOverlay [[texture(2)]],
                             constant uint &showText [[buffer(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // NV12 取樣
    float y = texY.sample(s, in.texCoord).r;
    float2 uv = texUV.sample(s, in.texCoord).rg;

    float Y = 1.1643 * (y - 0.0625);
    float U = uv.x - 0.5;
    float V = uv.y - 0.5;

    float R = Y + 1.5958 * V;
    float G = Y - 0.39173 * U - 0.81290 * V;
    float B = Y + 2.017 * U;

    float4 color = float4(R, G, B, 1.0);

    // 疊加文字貼圖 (左上角顯示)
    if (showText != 0) {
        if (in.texCoord.x < 0.25 && in.texCoord.y < 0.1) {
            float2 overlayUV = float2(in.texCoord.x / 0.25,
                                    1.0 - (in.texCoord.y / 0.1));

            float4 overlay = textOverlay.sample(s, overlayUV);

            // textOverlay is uploaded from a premultiplied-alpha BGRA bitmap.
            color.rgb = color.rgb * (1.0 - overlay.a) + overlay.rgb;
        }
    }


    return color;
}

