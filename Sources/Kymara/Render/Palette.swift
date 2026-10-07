import Foundation
import Metal

enum WaterfallPalette: String, CaseIterable, Identifiable, Codable {
    case classic = "Classic"
    case turbo = "Turbo"
    case viridis = "Viridis"
    case hot = "Hot"
    case blue = "Blue"
    case grayscale = "Grayscale"

    var id: String { rawValue }

    /// Gradient stops (position, r, g, b). The light variant maps the noise floor to near-white and
    /// strong signals to dark, saturated colours.
    private func stops(light: Bool) -> [(Double, Double, Double, Double)] {
        if light { return lightStops }
        switch self {
        case .classic:
            return [(0, 0, 0, 0.05), (0.2, 0, 0.05, 0.45), (0.4, 0, 0.55, 0.9), (0.6, 0.1, 0.95, 0.6),
                    (0.75, 0.95, 0.95, 0.1), (0.9, 1, 0.3, 0), (1, 1, 1, 1)]
        case .turbo:
            return [(0, 0.19, 0.07, 0.23), (0.15, 0.27, 0.42, 0.93), (0.3, 0.1, 0.78, 0.86), (0.45, 0.25, 0.98, 0.45),
                    (0.6, 0.72, 0.97, 0.21), (0.75, 0.99, 0.69, 0.2), (0.88, 0.93, 0.32, 0.07), (1, 0.48, 0.02, 0.01)]
        case .viridis:
            return [(0, 0.27, 0.0, 0.33), (0.25, 0.23, 0.32, 0.55), (0.5, 0.13, 0.57, 0.55),
                    (0.75, 0.37, 0.79, 0.38), (1, 0.99, 0.91, 0.14)]
        case .hot:
            return [(0, 0, 0, 0), (0.35, 0.7, 0, 0), (0.65, 1, 0.6, 0), (0.85, 1, 1, 0.3), (1, 1, 1, 1)]
        case .blue:
            return [(0, 0.0, 0.02, 0.08), (0.4, 0.05, 0.2, 0.5), (0.7, 0.3, 0.6, 0.95), (1, 0.9, 0.97, 1)]
        case .grayscale:
            return [(0, 0, 0, 0), (1, 1, 1, 1)]
        }
    }

    private var lightStops: [(Double, Double, Double, Double)] {
        switch self {
        case .classic:
            return [(0, 0.98, 0.99, 1), (0.3, 0.86, 0.92, 0.98), (0.5, 0.55, 0.75, 0.95), (0.65, 0.3, 0.7, 0.55),
                    (0.78, 0.95, 0.75, 0.1), (0.9, 0.9, 0.3, 0), (1, 0.5, 0, 0.05)]
        case .turbo:
            return [(0, 0.98, 0.98, 0.99), (0.3, 0.82, 0.9, 0.98), (0.45, 0.45, 0.7, 0.95), (0.58, 0.25, 0.78, 0.6),
                    (0.7, 0.65, 0.85, 0.2), (0.8, 0.97, 0.65, 0.15), (0.9, 0.9, 0.3, 0.07), (1, 0.48, 0.02, 0.01)]
        case .viridis:
            return [(0, 0.98, 0.98, 0.94), (0.35, 0.82, 0.9, 0.6), (0.6, 0.13, 0.57, 0.55),
                    (0.8, 0.23, 0.32, 0.55), (1, 0.27, 0, 0.33)]
        case .hot:
            return [(0, 1, 1, 1), (0.4, 1, 0.93, 0.7), (0.65, 1, 0.6, 0.1), (0.85, 0.8, 0.15, 0), (1, 0.35, 0, 0)]
        case .blue:
            return [(0, 0.98, 0.99, 1), (0.45, 0.75, 0.85, 0.97), (0.75, 0.15, 0.4, 0.8), (1, 0, 0.08, 0.3)]
        case .grayscale:
            return [(0, 1, 1, 1), (1, 0, 0, 0)]
        }
    }

    func rgba(count: Int = 256, light: Bool = false) -> [UInt8] {
        let s = stops(light: light)
        var out = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            let x = Double(i) / Double(count - 1)
            var j = 0
            while j < s.count - 2 && x > s[j + 1].0 { j += 1 }
            let a = s[j], b = s[j + 1]
            let t = max(0, min(1, (x - a.0) / max(b.0 - a.0, 1e-9)))
            out[4 * i] = UInt8((a.1 + (b.1 - a.1) * t) * 255)
            out[4 * i + 1] = UInt8((a.2 + (b.2 - a.2) * t) * 255)
            out[4 * i + 2] = UInt8((a.3 + (b.3 - a.3) * t) * 255)
        }
        return out
    }

    @MainActor
    func makeTexture(device: MTLDevice, light: Bool) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let bytes = rgba(light: light)
        tex.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256 * 4)
        return tex
    }
}
