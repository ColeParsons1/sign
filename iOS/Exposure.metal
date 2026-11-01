#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The overall brightness control (Cole, 2026-10-29): the whole picture, every scene, scaled by `gain` (the Brightness
// slider: 0.2 dim … 1 as drawn … 2 bright). Brighter than drawn rolls off softly toward white instead of clipping, so a
// bright scene turned up keeps its colours and its highlights' shape.
[[ stitchable ]] half4 exposure(float2 position, half4 color, float gain) {
    float3 c = float3(color.rgb) * gain;
    if (gain > 1.0) {
        const float knee = 0.75;
        float3 over = max(c - knee, 0.0);
        c = min(c, knee) + over / (1.0 + over / (1.0 - knee));
    }
    return half4(half3(c), color.a);
}
