import MetalKit
import SDRCore

/// Scrolling waterfall: spectrum lines go into a ring texture (one row per line); the fragment shader
/// maps rows to time, applies the palette and compensates for retuning per row.
@MainActor
final class WaterfallRenderer: NSObject, MTKViewDelegate {
    static let rows = 2048
    static let maxWidth = 16384

    private let radio: RadioController
    private let ctx = MetalContext.shared
    private var texture: MTLTexture?
    private var sourceWidth = 0
    private var newestRow = 0
    private var rowCenters = [Double](repeating: .nan, count: WaterfallRenderer.rows)
    private var rowRate: Double = 0
    private var paletteTexture: MTLTexture?
    private var palette: WaterfallPalette?
    private var paletteLight = false
    private var shiftBuffers: [MTLBuffer] = []
    private var shiftIndex = 0
    private var shifts = [Float](repeating: 10, count: WaterfallRenderer.rows)
    private var half: [Float16] = []
    private let inflight = DispatchSemaphore(value: 3)

    init(radio: RadioController) {
        self.radio = radio
        super.init()
        for _ in 0..<3 {
            if let b = ctx.device.makeBuffer(length: WaterfallRenderer.rows * MemoryLayout<Float>.stride, options: .storageModeShared) {
                shiftBuffers.append(b)
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func clear() {
        rowCenters = [Double](repeating: .nan, count: WaterfallRenderer.rows)
    }

    private func makeTexture(width: Int) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width,
                                                            height: WaterfallRenderer.rows, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        texture = ctx.device.makeTexture(descriptor: desc)
        let blank = [Float16](repeating: -200, count: width)
        for row in 0..<WaterfallRenderer.rows {
            texture?.replace(region: MTLRegionMake2D(0, row, width, 1), mipmapLevel: 0,
                             withBytes: blank, bytesPerRow: width * 2)
        }
        clear()
    }

    private func upload(_ line: [Float]) {
        if line.count != sourceWidth || texture == nil {
            sourceWidth = line.count
            makeTexture(width: min(line.count, WaterfallRenderer.maxWidth))
        }
        guard let texture else { return }
        let w = texture.width
        if half.count != w { half = [Float16](repeating: -200, count: w) }
        if line.count == w {
            for i in 0..<w { half[i] = Float16(line[i]) }
        } else {
            let factor = line.count / w
            for i in 0..<w {
                var m: Float = -200
                let base = i * factor
                for j in 0..<factor where line[base + j] > m { m = line[base + j] }
                half[i] = Float16(m)
            }
        }
        newestRow = (newestRow + 1) % WaterfallRenderer.rows
        texture.replace(region: MTLRegionMake2D(0, newestRow, w, 1), mipmapLevel: 0, withBytes: half, bytesPerRow: w * 2)
        rowCenters[newestRow] = radio.centerFrequency
    }

    func draw(in view: MTKView) {
        let r = radio
        if rowRate != r.sampleRate {
            rowRate = r.sampleRate
            clear()
        }
        for line in r.engine.spectrum.drainLines() {
            upload(line)
        }
        // The light variant has a light noise floor.
        let light = r.displayTheme.isLight(in: view.effectiveAppearance)
        if palette != r.palette || paletteLight != light || paletteTexture == nil {
            palette = r.palette
            paletteLight = light
            paletteTexture = r.palette.makeTexture(device: ctx.device, light: light)
            view.clearColor = light ? MTLClearColor(red: 0.97, green: 0.98, blue: 1, alpha: 1)
                                    : MTLClearColor(red: 0.02, green: 0.025, blue: 0.04, alpha: 1)
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        guard let texture, let paletteTexture, shiftBuffers.count == 3 else {
            // Nothing received yet: just clear.
            if let cmd = ctx.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                enc.endEncoding()
                cmd.present(drawable)
                cmd.commit()
            }
            return
        }

        let fs = r.sampleRate
        let bandStart = r.centerFrequency - fs / 2
        for i in 0..<WaterfallRenderer.rows {
            let c = rowCenters[i]
            shifts[i] = c.isNaN ? 10 : Float((r.centerFrequency - c) / fs)
        }
        inflight.wait()
        shiftIndex = (shiftIndex + 1) % 3
        let shiftBuffer = shiftBuffers[shiftIndex]
        shifts.withUnsafeBytes { shiftBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        let scale = Double(view.window?.backingScaleFactor ?? 2)
        var u = WaterfallUniforms()
        u.newestRow = Float(newestRow)
        u.rows = Float(WaterfallRenderer.rows)
        u.visibleRows = Float(min(Double(WaterfallRenderer.rows), Double(view.drawableSize.height) / scale))
        u.uStart = Float((r.viewStart - bandStart) / fs)
        u.uEnd = Float((r.viewEnd - bandStart) / fs)
        u.minDB = Float(r.waterfallMin)
        u.maxDB = Float(max(r.waterfallMax, r.waterfallMin + 1))
        u.filterStart = Float((r.filterStart - bandStart) / fs)
        u.filterEnd = Float((r.filterEnd - bandStart) / fs)
        u.vfo = Float((r.vfoFrequency - bandStart) / fs)
        u.light = light ? 1 : 0
        u.texelsPerPixel = (u.uEnd - u.uStart) * Float(texture.width) / Float(max(1, view.drawableSize.width))

        guard let cmd = ctx.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            return
        }
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        enc.setRenderPipelineState(ctx.waterfallPipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentTexture(paletteTexture, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<WaterfallUniforms>.stride, index: 0)
        enc.setFragmentBuffer(shiftBuffer, offset: 0, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
