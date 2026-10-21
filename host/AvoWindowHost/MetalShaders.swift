/// The renderer's Metal shaders, compiled once per window at startup.
///
/// Every pass draws the same full-viewport quad (`avo_vertex`); the viewport
/// places it, so the fragment shaders work in drawable pixels or in the
/// quad's 0...1 texture coordinates. Every fragment shader returns alpha 1:
/// the guest leaves the alpha byte undefined, and the layer is opaque.
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
    """
}
