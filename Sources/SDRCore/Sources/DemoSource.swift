import Foundation
import Accelerate

/// Synthesises a band full of signals (broadcast FM, AM, NFM, SSB, CW) so the app can be used without hardware.
public final class DemoSource: IQSource, @unchecked Sendable {
    public let displayName = "Demo signal generator"
    public var gains: [Int] { TunerGains.r820t }
    public var onError: ((String) -> Void)?
    public var onInfoChanged: (() -> Void)?

    enum Kind {
        case wfm(stereo: Bool)
        case nfm
        case am
        case cw
        case usb
        case lsb
    }

    struct Emitter {
        let frequency: Double
        let kind: Kind
        let level: Float
        let seed: Double
    }

    static let emitters: [Emitter] = [
        Emitter(frequency: 7_100_000, kind: .lsb, level: 0.05, seed: 0.3),
        Emitter(frequency: 7_150_000, kind: .lsb, level: 0.02, seed: 2.1),
        Emitter(frequency: 14_200_000, kind: .usb, level: 0.04, seed: 1.2),
        Emitter(frequency: 14_060_000, kind: .cw, level: 0.03, seed: 0),
        Emitter(frequency: 99_300_000, kind: .wfm(stereo: false), level: 0.05, seed: 0.7),
        Emitter(frequency: 99_500_000, kind: .usb, level: 0.03, seed: 0.1),
        Emitter(frequency: 99_650_000, kind: .nfm, level: 0.04, seed: 1.7),
        Emitter(frequency: 100_000_000, kind: .wfm(stereo: true), level: 0.35, seed: 0),
        Emitter(frequency: 100_350_000, kind: .am, level: 0.08, seed: 0.9),
        Emitter(frequency: 100_450_000, kind: .cw, level: 0.03, seed: 0.4),
        Emitter(frequency: 100_700_000, kind: .wfm(stereo: false), level: 0.12, seed: 2.5),
        Emitter(frequency: 101_200_000, kind: .wfm(stereo: true), level: 0.2, seed: 1.1),
        Emitter(frequency: 124_000_000, kind: .am, level: 0.06, seed: 1.3),
        Emitter(frequency: 124_325_000, kind: .am, level: 0.03, seed: 2.2),
        Emitter(frequency: 145_500_000, kind: .nfm, level: 0.06, seed: 0.2),
        Emitter(frequency: 145_525_000, kind: .nfm, level: 0.03, seed: 3.1),
        Emitter(frequency: 156_800_000, kind: .nfm, level: 0.05, seed: 0.6),
        Emitter(frequency: 446_006_250, kind: .nfm, level: 0.07, seed: 1.9),
        Emitter(frequency: 433_920_000, kind: .cw, level: 0.04, seed: 0.8),
    ]

    private let lock = NSLock()
    private var center: Double = 100_000_000
    private var gainDB: Double = 30
    private var running = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    public init() {}

    deinit { stop() }

    public func start(sampleRate: Double, centerFrequency: Double, handler: @escaping IQHandler) throws {
        stop()
        lock.lock()
        center = centerFrequency
        running = true
        lock.unlock()
        let generator = Generator(sampleRate: sampleRate)
        let thread = Thread { [weak self] in
            var pacer = RealTimePacer(rate: sampleRate)
            let block = max(1024, Int(sampleRate / 100))
            var bytes = [UInt8](repeating: 127, count: block * 2)
            while let self, self.isRunning {
                self.lock.lock()
                let c = self.center
                let g = self.gainDB
                self.lock.unlock()
                generator.generate(into: &bytes, count: block, center: c, gainDB: g)
                bytes.withUnsafeBufferPointer { handler($0) }
                pacer.wait(afterProducing: block)
            }
            self?.finished.signal()
        }
        thread.name = "Demo generator"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning, thread != nil {
            _ = finished.wait(timeout: .now() + 2)
        }
        thread = nil
    }

    public func setCenterFrequency(_ hz: Double) {
        lock.lock()
        center = hz
        lock.unlock()
    }

    public func setGain(_ tenthsDB: Int?) {
        lock.lock()
        gainDB = tenthsDB.map { Double($0) / 10 } ?? 30
        lock.unlock()
    }
}

/// Sine/cosine oscillator by complex rotation (cheap per-sample tones).
struct Rotator {
    private var c = 1.0
    private var s = 0.0
    private var dc = 1.0
    private var ds = 0.0

    init(frequency: Double, sampleRate: Double) {
        setFrequency(frequency, sampleRate: sampleRate)
    }

    mutating func setFrequency(_ f: Double, sampleRate: Double) {
        dc = cos(2 * .pi * f / sampleRate)
        ds = sin(2 * .pi * f / sampleRate)
    }

    var sinValue: Double { s }
    var cosValue: Double { c }

    mutating func advance() {
        let nc = c * dc - s * ds
        s = s * dc + c * ds
        c = nc
    }

    mutating func normalize() {
        let m = 1 / (c * c + s * s).squareRoot()
        c *= m
        s *= m
    }
}

private final class Generator {
    let fs: Double
    private var time: Double = 0
    private var phases: [Double]
    private var keyLevel: [Double]
    private var noiseI: [Float] = []
    private var noiseQ: [Float] = []
    private var accI: [Float] = []
    private var accQ: [Float] = []
    private var phaseF: [Float] = []
    private var ampF: [Float] = []
    private var sinBuf: [Float] = []
    private var cosBuf: [Float] = []
    private var interleaved: [Float] = []
    private var tone1: [Rotator]
    private var tone2: [Rotator]
    private var pilot: Rotator
    private let morse: [Bool]

    init(sampleRate: Double) {
        fs = sampleRate
        let n = DemoSource.emitters.count
        phases = [Double](repeating: 0, count: n)
        keyLevel = [Double](repeating: 0, count: n)
        tone1 = DemoSource.emitters.enumerated().map { i, _ in Rotator(frequency: 600 + Double(i) * 70, sampleRate: sampleRate) }
        tone2 = DemoSource.emitters.enumerated().map { i, _ in Rotator(frequency: 1100 + Double(i) * 37, sampleRate: sampleRate) }
        pilot = Rotator(frequency: 19_000, sampleRate: sampleRate)
        morse = Generator.morsePattern("CQ CQ DE PA0SDR PA0SDR K   ")

        let noiseCount = 1 << 18
        noiseI = [Float](repeating: 0, count: noiseCount)
        noiseQ = [Float](repeating: 0, count: noiseCount)
        var rng = SystemRandomNumberGenerator()
        for k in 0..<noiseCount {
            let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-12)
            let u2 = Double.random(in: 0..<1, using: &rng)
            let r = (-2 * log(u1)).squareRoot() * 0.006
            noiseI[k] = Float(r * cos(2 * .pi * u2))
            noiseQ[k] = Float(r * sin(2 * .pi * u2))
        }
    }

    @inline(__always)
    private func wrap(_ phase: inout Double) -> Double {
        if phase > .pi { phase -= 2 * .pi } else if phase < -.pi { phase += 2 * .pi }
        return phase
    }

    static func morsePattern(_ text: String) -> [Bool] {
        let table: [Character: String] = [
            "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....",
            "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.",
            "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
            "Y": "-.--", "Z": "--..", "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
            "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ]
        var units: [Bool] = []
        for ch in text {
            if ch == " " {
                units += [false, false, false, false]
                continue
            }
            guard let code = table[ch] else { continue }
            for sym in code {
                units += sym == "." ? [true] : [true, true, true]
                units.append(false)
            }
            units += [false, false]
        }
        return units
    }

    private func ensure(_ n: Int) {
        guard accI.count < n else { return }
        accI = [Float](repeating: 0, count: n)
        accQ = accI
        phaseF = accI
        ampF = accI
        sinBuf = accI
        cosBuf = accI
        interleaved = [Float](repeating: 0, count: 2 * n)
    }

    func generate(into bytes: inout [UInt8], count n: Int, center: Double, gainDB: Double) {
        ensure(n)
        let offset = Int.random(in: 0..<(noiseI.count - n))
        noiseI.withUnsafeBufferPointer { accI.replaceSubrange(0..<n, with: $0[offset..<(offset + n)]) }
        noiseQ.withUnsafeBufferPointer { accQ.replaceSubrange(0..<n, with: $0[offset..<(offset + n)]) }

        let dt = 1 / fs
        let phasePtr = phaseF.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let ampPtr = ampF.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let morse = self.morse
        for (e, emitter) in DemoSource.emitters.enumerated() {
            let off = emitter.frequency - center
            guard abs(off) < fs / 2 + 120_000 else { continue }
            var phase = phases[e]
            var key = keyLevel[e]
            var t1 = tone1[e]
            var t2 = tone2[e]
            var p19 = pilot
            let level = Double(emitter.level)
            let baseInc = 2 * .pi * off * dt
            let tBlock = time + emitter.seed * 10
            let phaseF = phasePtr, ampF = ampPtr

            switch emitter.kind {
            case .wfm(let stereo):
                // Alternating tones per channel so stereo separation is audible.
                let leftOn = sin(2 * .pi * tBlock / 4) > 0
                let k = 2 * .pi * 75_000 * dt
                for i in 0..<n {
                    let left = leftOn ? 0.8 * t1.sinValue : 0.15 * t2.sinValue
                    let right = leftOn ? 0.15 * t1.sinValue : 0.8 * t2.sinValue
                    var mpx: Double
                    if stereo {
                        let s19 = p19.sinValue
                        let s38 = 2 * s19 * p19.cosValue
                        mpx = 0.45 * (left + right) + 0.45 * (left - right) * s38 + 0.1 * s19
                    } else {
                        mpx = 0.5 * (left + right)
                    }
                    phase += baseInc + k * mpx
                    phaseF[i] = Float(wrap(&phase))
                    ampF[i] = Float(level)
                    t1.advance(); t2.advance(); p19.advance()
                }
            case .nfm:
                let on = sin(2 * .pi * tBlock / 7 + emitter.seed) > -0.2
                let target = on ? 1.0 : 0.0
                let k = 2 * .pi * 3_000 * dt
                let warble = sin(2 * .pi * tBlock * 3)
                for i in 0..<n {
                    key += (target - key) * 0.0005
                    let m = on ? (0.6 * t1.sinValue + 0.3 * t2.sinValue * warble) : 0
                    phase += baseInc + k * m
                    phaseF[i] = Float(wrap(&phase))
                    ampF[i] = Float(level * key)
                    t1.advance(); t2.advance()
                }
            case .am:
                let speech = 0.5 + 0.5 * sin(2 * .pi * tBlock * 0.7)
                for i in 0..<n {
                    let m = speech * (0.5 * t1.sinValue + 0.3 * t2.sinValue)
                    phase += baseInc
                    phaseF[i] = Float(wrap(&phase))
                    ampF[i] = Float(level * (1 + 0.8 * m))
                    t1.advance(); t2.advance()
                }
            case .cw:
                let unit = 0.06
                let tau = 1 / (fs * 0.004)
                for i in 0..<n {
                    let t = tBlock + Double(i) * dt
                    let idx = Int(t / unit) % morse.count
                    key += ((morse[idx] ? 1 : 0) - key) * tau
                    phase += baseInc
                    phaseF[i] = Float(wrap(&phase))
                    ampF[i] = Float(level * key)
                }
            case .usb, .lsb:
                let sign: Double = { if case .lsb = emitter.kind { return -1 } else { return 1 } }()
                let syllable = max(0, sin(2 * .pi * tBlock * 2.3) + 0.3 * sin(2 * .pi * tBlock * 0.37))
                let tau = 1 / (fs * 0.01)
                for i in 0..<n {
                    let t = tBlock + Double(i) * dt
                    let audioF = 800 + 900 * (0.5 + 0.5 * sin(2 * .pi * 0.4 * t))
                    key += (syllable - key) * tau
                    phase += baseInc + sign * 2 * .pi * audioF * dt
                    phaseF[i] = Float(wrap(&phase))
                    ampF[i] = Float(level * key)
                }
            }
            t1.normalize(); t2.normalize()
            tone1[e] = t1
            tone2[e] = t2
            phases[e] = phase.remainder(dividingBy: 2 * .pi)
            keyLevel[e] = key

            var count32 = Int32(n)
            vvsincosf(&sinBuf, &cosBuf, phasePtr, &count32)
            accI.inPlace { vDSP_vma(cosBuf, 1, ampPtr, 1, $0, 1, $0, 1, vDSP_Length(n)) }
            accQ.inPlace { vDSP_vma(sinBuf, 1, ampPtr, 1, $0, 1, $0, 1, vDSP_Length(n)) }
        }
        for _ in 0..<n { pilot.advance() }
        pilot.normalize()
        time += Double(n) * dt

        // Gain → scale, then quantise to u8 like the real dongle (clipping included).
        var scale = Float(pow(10, (gainDB - 30) / 20)) * 127.5
        var bias: Float = 127.5
        var lo: Float = 0
        var hi: Float = 255
        accI.withUnsafeBufferPointer { ip in
            accQ.withUnsafeBufferPointer { qp in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: ip.baseAddress!),
                                            imagp: UnsafeMutablePointer(mutating: qp.baseAddress!))
                interleaved.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n))
                    }
                }
            }
        }
        let total = vDSP_Length(2 * n)
        interleaved.inPlace { vDSP_vsmsa($0, 1, &scale, &bias, $0, 1, total) }
        interleaved.inPlace { vDSP_vclip($0, 1, &lo, &hi, $0, 1, total) }
        vDSP_vfixru8(interleaved, 1, &bytes, 1, total)
    }
}
