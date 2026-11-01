// "Sign" (Cole, 2026-11-01): a canvas of hexagons that fit perfectly, on which a hand fingerspells the words being sung,
// in the ASL manual alphabet. The hand is drawn by the tiles themselves: each tile takes the colour of whatever bone of
// the hand covers its centre (SignHand.swift projects the bones as capsules with their depth), nearer bones brighter, a
// seam of shadow where one bone crosses another, the thumb in a warmer light than the fingers so where it sits (which
// tells A from S from T, M and N) reads at a glance. The rest of the canvas glows faintly and ripples with the beat.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant int SG_CAPS = 20;

static float sgSat(float x) { return clamp(x, 0.0, 1.0); }
static float3 sgOklch(float L, float C, float hDeg) {
    float h = hDeg * (3.14159265 / 180.0), a = C * cos(h), b = C * sin(h);
    float l = L + 0.3963377774 * a + 0.2158037573 * b;
    float m = L - 0.1055613458 * a - 0.0638541728 * b;
    float s = L - 0.0894841775 * a - 1.2914855480 * b;
    l = l * l * l; m = m * m * m; s = s * s * s;
    float3 lin = float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    return pow(clamp(lin, 0.0, 1.0), float3(1.0 / 2.2));
}
static float sgHash(float2 p) {
    p = fract(p * float2(127.1, 311.7));
    p += dot(p, p + 34.45);
    return fract(p.x * p.y);
}

[[ stitchable ]] half4 sign(float2 position, half4 color, float2 size, float t, float4 a1, float4 a2, float4 a3,
                           device const float *c, int count) {
    float energy = a1.x, pulse = a1.y, visible = a1.z, hue = a1.w;
    float bass = a2.x, snare = a2.y, hat = a2.z, voice = a2.w;
    float dropAge = a3.x;
    float S = 0.5 * min(size.x, size.y);
    float2 mid = float2(0.5 * size.x, 0.5 * size.y);

    // the tiles: pointy-topped hexagons, a little over a hundredth of the screen across
    float R = S * 0.0125;
    float2 x = position - mid;
    float qa = (0.57735027 * x.x - 0.33333333 * x.y) / R, ra = (0.66666667 * x.y) / R;
    float3 cube = float3(qa, ra, -qa - ra), rc = round(cube), df = abs(rc - cube);
    if (df.x > df.y && df.x > df.z) rc.x = -rc.y - rc.z; else if (df.y > df.z) rc.y = -rc.x - rc.z;
    float2 centre = float2(R * 1.7320508 * (rc.x + 0.5 * rc.y), R * 1.5 * rc.y);
    float2 lp = x - centre;
    float hexD = max(abs(lp.x), max(abs(dot(lp, float2(0.5, 0.8660254))), abs(dot(lp, float2(-0.5, 0.8660254)))));
    float grout = smoothstep(R * 0.80, R * 0.70, hexD);           // (1 inside the tile, 0 in the grout)
    float2 cell = rc.xy;

    // the hand at this tile's centre: the nearest bone covering it, and the one under that
    float2 hp = float2(centre.x, -centre.y) / S;
    float top = -9.0, second = -9.0, part = -1.0, partUnder = -1.0, edge = 0.0, nearOut = 9.0, along = 0.0;
    if (count >= 8 * SG_CAPS && visible > 0.01) {
        for (int i = 0; i < SG_CAPS; i++) {
            float2 A = float2(c[8 * i], c[8 * i + 1]), B = float2(c[8 * i + 2], c[8 * i + 3]);
            float rr = c[8 * i + 4];
            float2 ab = B - A;
            float h = sgSat(dot(hp - A, ab) / max(dot(ab, ab), 1e-6));
            float d = length(hp - A - ab * h);
            nearOut = min(nearOut, d - rr);
            if (d < rr) {
                float z = mix(c[8 * i + 5], c[8 * i + 6], h) + sqrt(max(rr * rr - d * d, 0.0));   // (its rounded front)
                if (z > top) {
                    second = top; partUnder = part; top = z; part = c[8 * i + 7]; edge = (rr - d) / rr;
                    // how far out along its finger or thumb (0 at the knuckle … 1 at the tip), for the gradient
                    along = i >= 17 ? (float(i - 17) + h) / 3.0 : i >= 5 ? (float((i - 5) % 3) + h) / 3.0 : 0.0;
                }
                else if (z > second) { second = z; partUnder = c[8 * i + 7]; }
            }
        }
    }

    // the canvas: dark tiles, each its own faint shade, a ring of light rolling out from the middle on each beat
    float r0 = length(x) / S;
    float h1 = sgHash(cell);
    float3 col = float3(0.020, 0.024, 0.040) * (0.7 + 0.6 * h1);
    float ring = exp(-pow((r0 - (1.0 - pulse) * 1.6) / 0.10, 2.0)) * pulse;
    col += float3(0.10, 0.16, 0.30) * ring * (0.4 + 0.6 * energy);
    col += float3(0.05, 0.08, 0.16) * step(0.985, sgHash(cell + floor(t * 2.0))) * energy;   // (a few tiles glinting)
    // a dark border round the hand, so its outline is clean against any glint
    col *= 1.0 - 0.8 * visible * (1.0 - smoothstep(0.0, 0.03, nearOut)) * (part < 0.0 ? 1.0 : 0.0);

    if (part >= 0.0) {
        // the hand's colours, from the music (Cole, 2026-11-01): the harmony's hue, the fingers a gradient from it at the
        // knuckle to a neighbouring hue at the tip, the palm a deeper shade, the thumb from across the wheel so where it
        // sits still reads at a glance; each tile a hair its own shade, like stained glass. Fuller and brighter as the
        // music is louder and while someone sings; nearer bones brighter
        float jit = (sgHash(cell + 3.7) - 0.5) * 14.0;
        float rich = 0.10 + 0.07 * sgSat(energy * 1.3) + 0.05 * sgSat(voice);
        float near = sgSat((top + 0.25) / 0.75);
        float Lh = 0.50 + 0.30 * near + 0.06 * sgSat(voice);
        float3 handC = part < 0.5 ? sgOklch(Lh - 0.14 + 0.18 * sgSat(bass), rich * 0.85, hue - 25.0 + jit)  // the palm, glowing with the bass
                     : part > 4.5 ? sgOklch(Lh + 0.06, rich + 0.03, hue + 165.0 + 30.0 * along + jit)        // the thumb
                     : sgOklch(Lh + 0.04 * along, rich, hue + 55.0 * along + jit);                          // the fingers
        // the beat runs up the hand, a band of light from the wrist to the fingertips
        float2 wrist = count >= 8 * SG_CAPS ? float2(c[8 * 4 + 2], c[8 * 4 + 3]) : float2(0.0);
        float up = length(hp - wrist) / 0.95;
        float xb = (up - (1.0 - pulse) * 1.25) / 0.12;
        handC *= 1.0 + 0.55 * exp(-xb * xb) * pulse;
        // the snare flashes the fingertips; the hats glitter tile by tile; a drop flashes the whole hand
        handC += sgOklch(0.92, 0.06, hue + 55.0) * snare * smoothstep(0.65, 1.0, along) * 0.55;
        handC *= 1.0 + 0.9 * hat * step(0.90, sgHash(cell + floor(t * 14.0)));
        handC = mix(handC, float3(1.0), 0.7 * exp(-dropAge / 0.35));
        // a seam where this bone lies over another, and its own rim a little darker, so the fingers read apart
        float seam = (part != partUnder && partUnder >= 0.0) ? (1.0 - smoothstep(0.0, 0.35, edge)) : 0.0;
        handC *= 1.0 - 0.55 * seam;
        handC *= 0.80 + 0.20 * smoothstep(0.0, 0.30, edge);
        col = mix(col, handC, visible);
    }
    col *= mix(0.35, 1.0, grout);
    col += (sgHash(position) - 0.5) * 0.004;
    return half4(half3(max(col, 0.0)), 1.0h);
}
