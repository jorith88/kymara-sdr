import MetalKit
import simd
import SDRCore

private struct DrawRange {
    let start: Int
    let count: Int
    let type: MTLPrimitiveType
}

private extension SIMD4 where Scalar == Float {
    static func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> SIMD4<Float> { SIMD4(r, g, b, a) }
}

/// Colours for the spectrum display, per theme.
private struct SpectrumColors {
    let bgTop, bgBottom, outside, grid, passband, passbandEdge, fillTop, fillBottom, peak, trace, hover, hoverPassband, vfo, centre: SIMD4<Float>

    static let dark = SpectrumColors(
        bgTop: .rgba(0.05, 0.08, 0.15), bgBottom: .rgba(0.01, 0.015, 0.03), outside: .rgba(0, 0, 0, 0.45),
        grid: .rgba(0.5, 0.65, 0.85, 0.26), passband: .rgba(0.75, 0.82, 0.95, 0.13), passbandEdge: .rgba(0.8, 0.88, 1, 0.6),
        fillTop: .rgba(0.2, 0.6, 1, 0.6), fillBottom: .rgba(0.05, 0.25, 0.6, 0.08), peak: .rgba(1, 0.75, 0.25, 0.65),
        trace: .rgba(0.85, 0.95, 1, 1), hover: .rgba(1, 1, 1, 0.35), hoverPassband: .rgba(1, 1, 1, 0.06), vfo: .rgba(1, 0.25, 0.2, 0.95),
        centre: .rgba(1, 0.8, 0.2, 0.8))

    static let light = SpectrumColors(
        bgTop: .rgba(1, 1, 1), bgBottom: .rgba(0.9, 0.92, 0.95), outside: .rgba(0.45, 0.48, 0.52, 0.22),
        grid: .rgba(0.15, 0.25, 0.4, 0.24), passband: .rgba(0, 0.35, 0.8, 0.09), passbandEdge: .rgba(0, 0.35, 0.75, 0.6),
        fillTop: .rgba(0.1, 0.45, 0.9, 0.5), fillBottom: .rgba(0.1, 0.45, 0.9, 0.07), peak: .rgba(0.9, 0.5, 0, 0.75),
        trace: .rgba(0.03, 0.2, 0.45, 1), hover: .rgba(0, 0, 0, 0.35), hoverPassband: .rgba(0, 0, 0, 0.05), vfo: .rgba(0.9, 0.15, 0.12, 0.95),
        centre: .rgba(0.9, 0.55, 0, 0.9))
}

/// Spectrum trace, fill, grid, passband and markers — all geometry rendered on the GPU.
@MainActor
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    private let radio: RadioController
    private let ctx = MetalContext.shared
    private let ring = VertexRing()
    private var columns: [Float] = []
    private var peakColumns: [Float] = []
    private var vertices: [ColorVertex] = []
    private var ranges: [DrawRange] = []

    init(radio: RadioController) {
        self.radio = radio
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Max-hold per screen column so carriers never disappear between bins.
    private func resample(_ bins: [Float], into out: inout [Float], width: Int, bandStart: Double, binHz: Double) {
        if out.count != width { out = [Float](repeating: -200, count: width) }
        guard !bins.isEmpty else {
            for i in 0..<width { out[i] = -200 }
            return
        }
        let span = radio.viewSpan
        let start = radio.viewStart
        let n = bins.count
        let colHz = span / Double(width)
        for c in 0..<width {
            let f0 = start + Double(c) * colHz
            let k0 = (f0 - bandStart) / binHz
            let k1 = k0 + colHz / binHz
            if k1 - k0 >= 1 {
                var lo = Int(k0.rounded()), hi = Int(k1.rounded())
                lo = max(0, min(n - 1, lo))
                hi = max(lo + 1, min(n, hi))
                var m: Float = -200
                for k in lo..<hi where bins[k] > m { m = bins[k] }
                out[c] = m
            } else {
                let k = (k0 + k1) / 2
                let i0 = max(0, min(n - 1, Int(floor(k))))
                let i1 = min(n - 1, i0 + 1)
                let t = Float(k - floor(k))
                out[c] = bins[i0] + (bins[i1] - bins[i0]) * t
            }
        }
    }

    private func add(_ type: MTLPrimitiveType, _ verts: [ColorVertex]) {
        guard !verts.isEmpty else { return }
        ranges.append(DrawRange(start: vertices.count, count: verts.count, type: type))
        vertices += verts
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        let width = max(2, Int(view.drawableSize.width))
        let height = max(2, Double(view.drawableSize.height))
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let r = radio
        let start = r.viewStart
        let span = r.viewSpan
        let top = r.spectrumTop
        let bottom = min(r.spectrumBottom, top - 10)
        func x(_ f: Double) -> Float { Float((f - start) / span * 2 - 1) }
        func y(_ db: Double) -> Float { Float((db - bottom) / (top - bottom) * 2 - 1) }

        let light = r.displayTheme.isLight(in: view.effectiveAppearance)
        let colors = light ? SpectrumColors.light : SpectrumColors.dark

        let bandStart = r.centerFrequency - r.sampleRate / 2
        r.engine.spectrum.withLatest { spectrum, peak, _ in
            let binHz = r.sampleRate / Double(max(spectrum.count, 1))
            resample(spectrum, into: &columns, width: width, bandStart: bandStart, binHz: binHz)
            if r.peakHold {
                resample(peak, into: &peakColumns, width: width, bandStart: bandStart, binHz: binHz)
            }
        }

        vertices.removeAll(keepingCapacity: true)
        ranges.removeAll(keepingCapacity: true)

        // Background gradient.
        let bgTop = colors.bgTop
        let bgBottom = colors.bgBottom
        add(.triangleStrip, [
            ColorVertex(position: [-1, -1], color: bgBottom), ColorVertex(position: [1, -1], color: bgBottom),
            ColorVertex(position: [-1, 1], color: bgTop), ColorVertex(position: [1, 1], color: bgTop),
        ])

        // Band edges outside the sampled bandwidth.
        let outside = colors.outside
        let bandLo = x(bandStart), bandHi = x(bandStart + r.sampleRate)
        if bandLo > -1 {
            add(.triangleStrip, quad(-1, -1, bandLo, 1, outside))
        }
        if bandHi < 1 {
            add(.triangleStrip, quad(bandHi, -1, 1, 1, outside))
        }

        // Grid.
        let pointsWidth = Double(width) / scale
        let gridColor = colors.grid
        var grid: [ColorVertex] = []
        for f in Axis.frequencyTicks(start: start, end: start + span, width: pointsWidth).ticks {
            let gx = x(f)
            grid += [ColorVertex(position: [gx, -1], color: gridColor), ColorVertex(position: [gx, 1], color: gridColor)]
        }
        for db in Axis.dbTicks(bottom: bottom, top: top, height: height / scale) {
            let gy = y(db)
            grid += [ColorVertex(position: [-1, gy], color: gridColor), ColorVertex(position: [1, gy], color: gridColor)]
        }
        add(.line, grid)

        // Passband.
        let fx0 = x(r.filterStart), fx1 = x(r.filterEnd)
        add(.triangleStrip, quad(fx0, -1, fx1, 1, colors.passband))
        let edge = colors.passbandEdge
        add(.line, [
            ColorVertex(position: [fx0, -1], color: edge), ColorVertex(position: [fx0, 1], color: edge),
            ColorVertex(position: [fx1, -1], color: edge), ColorVertex(position: [fx1, 1], color: edge),
        ])

        // Passband preview at the hover position.
        if let preview = r.hoverPassband {
            let px0 = x(preview.lo), px1 = x(preview.hi)
            add(.triangleStrip, quad(px0, -1, px1, 1, colors.hoverPassband))
            let c = colors.hover
            add(.line, [
                ColorVertex(position: [px0, -1], color: c), ColorVertex(position: [px0, 1], color: c),
                ColorVertex(position: [px1, -1], color: c), ColorVertex(position: [px1, 1], color: c),
            ])
        }

        // Fill under the trace.
        let w = Float(width)
        if r.fillSpectrum {
            var fill: [ColorVertex] = []
            fill.reserveCapacity(width * 2)
            let fillTop = colors.fillTop
            let fillBottom = colors.fillBottom
            for c in 0..<width {
                let px = (Float(c) + 0.5) / w * 2 - 1
                let py = max(-1, min(1, y(Double(columns[c]))))
                fill.append(ColorVertex(position: [px, py], color: fillTop))
                fill.append(ColorVertex(position: [px, -1], color: fillBottom))
            }
            add(.triangleStrip, fill)
        }

        // Peak hold.
        if r.peakHold, peakColumns.count == width {
            add(.triangleStrip, ribbon(peakColumns, width: width, height: height, thickness: 0.6 * scale,
                                       color: colors.peak, y: y))
        }

        // Trace as a thick ribbon (Metal lines are 1 px).
        add(.triangleStrip, ribbon(columns, width: width, height: height, thickness: 0.8 * scale,
                                   color: colors.trace, y: y))

        // Hover cursor.
        if let hover = r.hover {
            let hx = x(hover.frequency)
            let c = colors.hover
            var lines = [ColorVertex(position: [hx, -1], color: c), ColorVertex(position: [hx, 1], color: c)]
            if let db = hover.db {
                let hy = y(db)
                lines += [ColorVertex(position: [-1, hy], color: c), ColorVertex(position: [1, hy], color: c)]
            }
            add(.line, lines)
        }

        // VFO line (2 px wide).
        let vx = x(r.vfoFrequency)
        let vw = Float(1.0 / Double(width) * 2 * scale * 0.75)
        add(.triangleStrip, quad(vx - vw, -1, vx + vw, 1, colors.vfo))

        // Tuner centre marker.
        let cx = x(r.centerFrequency)
        let markerH = Float(14 * scale / height)
        add(.triangle, [
            ColorVertex(position: [cx, -1 + markerH], color: colors.centre),
            ColorVertex(position: [cx - markerH * Float(height) / w * 0.6, -1], color: colors.centre),
            ColorVertex(position: [cx + markerH * Float(height) / w * 0.6, -1], color: colors.centre),
        ])

        ring.semaphore.wait()
        guard let buffer = ring.next(vertices, device: ctx.device),
              let cmd = ctx.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            ring.semaphore.signal()
            return
        }
        let sem = ring.semaphore
        cmd.addCompletedHandler { _ in sem.signal() }
        enc.setRenderPipelineState(ctx.colorPipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        for range in ranges {
            enc.drawPrimitives(type: range.type, vertexStart: range.start, vertexCount: range.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: SIMD4<Float>) -> [ColorVertex] {
        [ColorVertex(position: [x0, y0], color: c), ColorVertex(position: [x1, y0], color: c),
         ColorVertex(position: [x0, y1], color: c), ColorVertex(position: [x1, y1], color: c)]
    }

    private func ribbon(_ values: [Float], width: Int, height: Double, thickness: Double,
                        color: SIMD4<Float>, y: (Double) -> Float) -> [ColorVertex] {
        var out: [ColorVertex] = []
        out.reserveCapacity(width * 2)
        let half = Float(thickness / height)
        let w = Float(width)
        for c in 0..<width {
            let px = (Float(c) + 0.5) / w * 2 - 1
            let py = y(Double(values[c]))
            out.append(ColorVertex(position: [px, py + half], color: color))
            out.append(ColorVertex(position: [px, py - half], color: color))
        }
        return out
    }
}
