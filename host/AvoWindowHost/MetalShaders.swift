/// The renderer's Metal shaders, compiled once per window at startup.
///
/// Every pass draws the same full-viewport quad (`avo_vertex`); the viewport
/// places it, so the fragment shaders work in drawable pixels or in the
/// quad's 0...1 texture coordinates. Every fragment shader but `avo_fade`
/// returns alpha 1: the guest leaves the alpha byte undefined, and the layer
/// is opaque.
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Out { float4 position [[position]]; float2 uv; };

    // rect = (left, top, width, height) in normalized device coordinates.
    vertex Out avo_vertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 c = corners[id];
        Out out;
        out.position = float4(rect.x + c.x * rect.z, rect.y - c.y * rect.w, 0, 1);
        out.uv = c;
        return out;
    }

    // Bilinear scaling (also the recorder's pass).
    fragment float4 avo_linear(Out in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(t.sample(s, in.uv).rgb, 1);
    }

    // Widget panels: Android's empty display around a widget is pure black,
    // which becomes transparent so the panel takes the widget's own shape.
    // A frame composed over black is premultiplied by its coverage already;
    // alpha ramps up over the darkest few steps, so antialiased edges fade
    // out and dark widget backgrounds stay solid.
    fragment float4 avo_keyed(Out in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 c = t.sample(s, in.uv).rgb;
        return float4(c, saturate(max(c.r, max(c.g, c.b)) / 0.06));
    }

    fragment float4 avo_nearest(Out in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return float4(t.sample(s, in.uv).rgb, 1);
    }

    // Shrinking: averages taps x taps bilinear samples spread over the
    // destination pixel's footprint, so nothing between samples is skipped
    // (plain bilinear aliases below half size). p = (1/destW, 1/destH, taps, 0).
    // Averaged in gamma space, as Android composes.
    fragment float4 avo_downsample(Out in [[stage_in]], texture2d<float> t [[texture(0)]],
                                   constant float4 &p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        int taps = max(int(p.z), 1);
        float3 sum = 0;
        for (int y = 0; y < taps; y++) {
            for (int x = 0; x < taps; x++) {
                float2 offset = (float2(x, y) + 0.5) / float(taps) - 0.5;
                sum += t.sample(s, in.uv + offset * p.xy).rgb;
            }
        }
        return float4(sum / float(taps * taps), 1);
    }

    // Texel at drawable pixel `position`, for a texture whose top-left
    // corner is at `origin`. The clamp repeats the edge pixels outside it,
    // which fills the few-pixel gap of a 1:1 frame instead of a black seam.
    static float3 texel(texture2d<float> t, float2 position, float2 origin, int2 offset) {
        int2 size = int2(t.get_width(), t.get_height());
        int2 c = clamp(int2(floor(position - origin)) + offset, int2(0), size - 1);
        return t.read(uint2(c)).rgb;
    }

    // 1:1 copy. p = (originX, originY, 0, 0).
    fragment float4 avo_copy(Out in [[stage_in]], texture2d<float> t [[texture(0)]],
                             constant float4 &p [[buffer(0)]]) {
        return float4(texel(t, in.position.xy, p.xy, int2(0)), 1);
    }

    // Robust Contrast-Adaptive Sharpening from AMD FidelityFX FSR 1 (MIT
    // licence, Copyright (c) 2021 Advanced Micro Devices, Inc.), without its
    // noise detection. Sharpens a 1:1 picture by at most what keeps every
    // pixel inside the range of its four neighbours, so it never rings.
    // p = (originX, originY, con, 0), con = exp2(-2 * (1 - sharpness)).
    fragment float4 avo_rcas(Out in [[stage_in]], texture2d<float> t [[texture(0)]],
                             constant float4 &p [[buffer(0)]]) {
        float3 b = texel(t, in.position.xy, p.xy, int2(0, -1));
        float3 d = texel(t, in.position.xy, p.xy, int2(-1, 0));
        float3 e = texel(t, in.position.xy, p.xy, int2(0, 0));
        float3 f = texel(t, in.position.xy, p.xy, int2(1, 0));
        float3 h = texel(t, in.position.xy, p.xy, int2(0, 1));
        float3 mn = min(min(b, d), min(f, h));
        float3 mx = max(max(b, d), max(f, h));
        // The centre counts too, as in FSR: a pixel already outside its ring
        // (a lone dot) is not pushed further. The divisors are kept away from
        // 0 (black or white neighbourhoods), where FSR's approximate
        // reciprocal returns a large finite value.
        float3 hitMin = min(mn, e) / max(4.0 * mx, 1e-5);
        float3 hitMax = (1.0 - max(mx, e)) / min(4.0 * mn - 4.0, -1e-5);
        float3 lobeC = max(-hitMin, hitMax);
        float lobe = max(-0.1875, min(max(lobeC.r, max(lobeC.g, lobeC.b)), 0.0)) * p.z;
        return float4(saturate((lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0)), 1);
    }

    // Behind a fitted frame instead of black bars, in three passes: the frame
    // shrunk to a few dozen pixels (avo_downsample), blurred there
    // (avo_blur), then stretched over the drawable, dimmed (avo_backdrop).

    // 5 x 5 Gaussian at the small size. p = (1/width, 1/height, 0, 0).
    fragment float4 avo_blur(Out in [[stage_in]], texture2d<float> t [[texture(0)]],
                             constant float4 &p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 sum = 0;
        float weight = 0;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                float w = exp(-float(x * x + y * y) / 4.5);
                sum += t.sample(s, in.uv + float2(x, y) * p.xy).rgb * w;
                weight += w;
            }
        }
        return float4(sum / weight, 1);
    }

    // Covers the drawable the way the frame would if cropped, with a cubic
    // B-spline from four bilinear taps, so the few pixels show no seams.
    // p = (the part of the small picture that shows: x, y, 0, 0).
    fragment float4 avo_backdrop(Out in [[stage_in]], texture2d<float> t [[texture(0)]],
                                 constant float4 &p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 size = float2(t.get_width(), t.get_height());
        float2 c = ((in.uv - 0.5) * p.xy + 0.5) * size - 0.5;
        float2 i = floor(c);
        float2 f = c - i;
        float2 w0 = (1 - f) * (1 - f) * (1 - f) / 6;
        float2 w1 = (3 * f * f * f - 6 * f * f + 4) / 6;
        float2 w3 = f * f * f / 6;
        float2 w2 = 1 - w0 - w1 - w3;
        float2 g0 = w0 + w1;
        float2 g1 = w2 + w3;
        float2 h0 = (i - 0.5 + w1 / g0) / size;
        float2 h1 = (i + 1.5 + w3 / g1) / size;
        float3 color = g0.y * (g0.x * t.sample(s, h0).rgb + g1.x * t.sample(s, float2(h1.x, h0.y)).rgb)
                     + g1.y * (g0.x * t.sample(s, float2(h0.x, h1.y)).rgb + g1.x * t.sample(s, h1).rgb);
        return float4(color * 0.5, 1);
    }

    // The previous frame fading out over the new one (the one shader that
    // returns another alpha: its pipeline blends). p = (alpha, 0, 0, 0).
    fragment float4 avo_fade(Out in [[stage_in]], texture2d<float> t [[texture(0)]],
                             constant float4 &p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(t.sample(s, in.uv).rgb, p.x);
    }
    """
}
