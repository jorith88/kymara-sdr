import Metal
import MetalKit
import simd

/// Shaders are compiled at runtime so the package builds without the offline Metal toolchain.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct ColorVertex {
    float2 position;
    float4 color;
};

struct VOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

vertex VOut colorVertex(uint vid [[vertex_id]], const device ColorVertex *v [[buffer(0)]]) {
    VOut o;
    o.position = float4(v[vid].position, 0, 1);
    o.color = v[vid].color;
    o.uv = float2(0);
    return o;
}

fragment float4 colorFragment(VOut in [[stage_in]]) {
    return in.color;
}

struct WaterfallUniforms {
    float newestRow;
    float rows;
    float visibleRows;
    float uStart;
    float uEnd;
    float minDB;
    float maxDB;
    float filterStart;
    float filterEnd;
    float vfo;
    float texelsPerPixel;
    float light;
    float hover;
    float scale;
    float previewStart;
    float previewEnd;
};

vertex VOut quadVertex(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o;
    o.position = float4(p[vid], 0, 1);
    o.uv = float2((p[vid].x + 1) * 0.5, (1 - p[vid].y) * 0.5);
    o.color = float4(0);
    return o;
}

// rowShift[r]: where row r's spectrum sits relative to the current tuner centre, in fractions of the sample rate.
fragment float4 waterfallFragment(VOut in [[stage_in]],
                                  texture2d<half, access::read> data [[texture(0)]],
                                  texture2d<half> palette [[texture(1)]],
                                  constant WaterfallUniforms &u [[buffer(0)]],
                                  const device float *rowShift [[buffer(1)]]) {
    constexpr sampler paletteSampler(filter::linear, address::clamp_to_edge);
    int rows = int(u.rows);
    // Newest line at the top, one texture row per screen row.
    int r = (int(u.newestRow) - int(floor(in.uv.y * u.visibleRows))) % rows;
    if (r < 0) { r += rows; }
    float xs = mix(u.uStart, u.uEnd, in.uv.x);
    float x = xs + rowShift[r];
    float w = float(data.get_width());
    float db = -200.0;
    if (x >= 0.0 && x <= 1.0) {
        float span = max(u.texelsPerPixel, 1.0);
        if (span <= 1.5) {
            float fx = clamp(x * w - 0.5, 0.0, w - 1.0);
            uint x0 = uint(floor(fx));
            uint x1 = min(x0 + 1, uint(w - 1.0));
            float a = fx - floor(fx);
            db = mix(float(data.read(uint2(x0, r)).r), float(data.read(uint2(x1, r)).r), a);
        } else {
            // Several texels per pixel: take the maximum so narrow carriers stay visible.
            int n = min(int(ceil(span)), 48);
            float first = x * w - span * 0.5;
            for (int i = 0; i < n; i++) {
                uint xi = uint(clamp(first + float(i), 0.0, w - 1.0));
                db = max(db, float(data.read(uint2(xi, r)).r));
            }
        }
    }
    float level = clamp((db - u.minDB) / max(u.maxDB - u.minDB, 1.0), 0.0, 1.0);
    float4 c = float4(palette.sample(paletteSampler, float2(level, 0.5)));
    if (x < 0.0 || x > 1.0) {
        c.rgb = u.light > 0.5 ? float3(0.86, 0.87, 0.89) : float3(0.03, 0.035, 0.05);
    }
    // Overlays. Lines take whichever of black/white contrasts with the pixel underneath,
    // so they stay visible on every palette.
    float px = fwidth(xs);
    float luma = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float3 contrast = luma > 0.5 ? float3(0.0) : float3(1.0);
    float lo = min(u.filterStart, u.filterEnd), hi = max(u.filterStart, u.filterEnd);
    if (xs >= lo && xs <= hi) {
        c.rgb = u.light > 0.5 ? mix(c.rgb, float3(0.0, 0.25, 0.6), 0.14) : mix(c.rgb, float3(0.75, 0.85, 1.0), 0.16);
    }
    // Passband edges, 1 pt wide.
    float edge = min(abs(xs - lo), abs(xs - hi));
    if (hi - lo > px * 4.0 && edge < px * u.scale * 0.5) {
        c.rgb = mix(c.rgb, contrast, 0.6);
    }
    // Passband preview at the hover position: light tint and dashed edges.
    if (u.previewEnd > u.previewStart) {
        if (xs >= u.previewStart && xs <= u.previewEnd) {
            c.rgb = mix(c.rgb, u.light > 0.5 ? float3(0.0) : float3(1.0), 0.07);
        }
        float pedge = min(abs(xs - u.previewStart), abs(xs - u.previewEnd));
        if (pedge < px * u.scale * 0.5 && fmod(in.position.y, 8.0 * u.scale) < 4.0 * u.scale) {
            c.rgb = mix(c.rgb, contrast, 0.5);
        }
    }
    // Hover cursor: dashed, so it can't be mistaken for the VFO.
    if (u.hover > -1000.0 && abs(xs - u.hover) < px * u.scale * 0.5 && fmod(in.position.y, 8.0 * u.scale) < 4.0 * u.scale) {
        c.rgb = mix(c.rgb, contrast, 0.75);
    }
    // VFO line, 2 pt wide.
    if (abs(xs - u.vfo) < px * u.scale) {
        c.rgb = mix(c.rgb, float3(1.0, 0.25, 0.2), 0.9);
    }
    return c;
}
"""

struct ColorVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

struct WaterfallUniforms {
    var newestRow: Float = 0
    var rows: Float = 0
    var visibleRows: Float = 0
    var uStart: Float = 0
    var uEnd: Float = 1
    var minDB: Float = -100
    var maxDB: Float = -40
    var filterStart: Float = 0
    var filterEnd: Float = 0
    var vfo: Float = 0
    var texelsPerPixel: Float = 1
    var light: Float = 0
    /// Hover frequency as a fraction of the band, or -1e6 when the mouse is outside the displays.
    var hover: Float = -1e6
    /// Backing scale factor, so overlay lines have a fixed width in points.
    var scale: Float = 2
    /// Passband preview at the hover position (fractions of the band); empty when start > end.
    var previewStart: Float = 1
    var previewEnd: Float = 0
}

@MainActor
final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let colorPipeline: MTLRenderPipelineState
    let waterfallPipeline: MTLRenderPipelineState

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this Mac")
        }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let color = MTLRenderPipelineDescriptor()
            color.vertexFunction = library.makeFunction(name: "colorVertex")
            color.fragmentFunction = library.makeFunction(name: "colorFragment")
            color.colorAttachments[0].pixelFormat = .bgra8Unorm
            color.colorAttachments[0].isBlendingEnabled = true
            color.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            color.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.colorAttachments[0].sourceAlphaBlendFactor = .one
            color.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            colorPipeline = try device.makeRenderPipelineState(descriptor: color)

            let wf = MTLRenderPipelineDescriptor()
            wf.vertexFunction = library.makeFunction(name: "quadVertex")
            wf.fragmentFunction = library.makeFunction(name: "waterfallFragment")
            wf.colorAttachments[0].pixelFormat = .bgra8Unorm
            waterfallPipeline = try device.makeRenderPipelineState(descriptor: wf)
        } catch {
            fatalError("Shader compilation failed: \(error)")
        }
    }
}

/// Triple-buffered per-frame vertex storage.
@MainActor
final class VertexRing {
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var index = 0
    let semaphore = DispatchSemaphore(value: 3)

    func next(_ vertices: [ColorVertex], device: MTLDevice) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        index = (index + 1) % buffers.count
        let length = vertices.count * MemoryLayout<ColorVertex>.stride
        if buffers[index] == nil || buffers[index]!.length < length {
            buffers[index] = device.makeBuffer(length: max(length * 2, 65536), options: .storageModeShared)
        }
        guard let buffer = buffers[index] else { return nil }
        vertices.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        return buffer
    }
}
