import Foundation

/// Tick computations shared by the GPU grid and the SwiftUI labels so they line up exactly.
enum Axis {
    static func niceStep(range: Double, maxTicks: Int) -> Double {
        guard range > 0, maxTicks > 0 else { return 1 }
        let raw = range / Double(maxTicks)
        let mag = pow(10, floor(log10(raw)))
        for m in [1.0, 2.0, 2.5, 5.0, 10.0] where m * mag >= raw {
            return m * mag
        }
        return 10 * mag
    }

    static func frequencyTicks(start: Double, end: Double, width: Double) -> (step: Double, ticks: [Double]) {
        let step = niceStep(range: end - start, maxTicks: max(2, Int(width / 110)))
        var ticks: [Double] = []
        var f = ceil(start / step) * step
        while f <= end && ticks.count < 200 {
            ticks.append(f)
            f += step
        }
        return (step, ticks)
    }

    /// Step for unlabelled ticks between the `major` ones: the finest even subdivision that keeps them
    /// at least `minSpacing` points apart, or `major` itself when none fits.
    static func minorStep(major: Double, range: Double, width: Double, minSpacing: Double = 8) -> Double {
        let mantissa = major / pow(10, floor(log10(major)))
        let divisions: [Double] = switch (mantissa * 10).rounded() {
        case 25: [5]
        case 20: [10, 4, 2]
        case 50: [10, 5]
        default: [10, 5, 2]
        }
        for n in divisions where major / n / range * width >= minSpacing {
            return major / n
        }
        return major
    }

    static func dbTicks(bottom: Double, top: Double, height: Double) -> [Double] {
        let step = niceStep(range: top - bottom, maxTicks: max(2, Int(height / 45)))
        var ticks: [Double] = []
        var d = ceil(bottom / step) * step
        while d <= top && ticks.count < 100 {
            ticks.append(d)
            d += step
        }
        return ticks
    }

    /// MHz label with at least three decimals, more when the step needs them.
    static func frequencyLabel(_ hz: Double, step: Double) -> String {
        let mhz = hz / 1e6
        let s = step / 1e6
        var decimals = 3
        while decimals < 6 {
            let scaled = s * pow(10, Double(decimals))
            if abs(scaled - scaled.rounded()) < 1e-6 { break }
            decimals += 1
        }
        return String(format: "%.\(decimals)f", mhz)
    }
}

enum FrequencyFormat {
    /// "145.500.000" style.
    static func dotted(_ hz: Double) -> String {
        let v = Int64(max(0, hz.rounded()))
        let s = String(v)
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return out
    }

    /// Compact chip label: "6.25k", "180k", "500".
    static func compact(_ hz: Double) -> String {
        if hz >= 1e3 {
            let k = hz / 1e3
            var t = String(format: "%.2f", k)
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t + "k"
        }
        return String(format: "%.0f", hz)
    }

    static func short(_ hz: Double) -> String {
        if hz >= 1e6 { return String(format: "%.4f MHz", hz / 1e6) }
        if hz >= 1e3 { return String(format: "%.2f kHz", hz / 1e3) }
        return String(format: "%.0f Hz", hz)
    }

    static func bandwidth(_ hz: Double) -> String {
        if hz >= 1e6 { return String(format: "%.2f MHz", hz / 1e6) }
        if hz >= 1e3 { return compact(hz).dropLast() + " kHz" }
        return String(format: "%.0f Hz", hz)
    }

    /// Parses "145.5", "145.5M", "7100k", "100000000", "1.2G". Bare numbers below 10 000 are MHz.
    static func parse(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        t = t.replacingOccurrences(of: "hz", with: "").replacingOccurrences(of: " ", with: "")
        var mult = 0.0
        if t.hasSuffix("g") { mult = 1e9; t.removeLast() }
        else if t.hasSuffix("m") { mult = 1e6; t.removeLast() }
        else if t.hasSuffix("k") { mult = 1e3; t.removeLast() }
        // Allow dotted thousands like 145.500.000.
        if t.filter({ $0 == "." }).count > 1 { t = t.replacingOccurrences(of: ".", with: "") ; if mult == 0 { mult = 1 } }
        guard let v = Double(t), v >= 0 else { return nil }
        if mult == 0 { mult = v < 10_000 ? 1e6 : 1 }
        return v * mult
    }
}
