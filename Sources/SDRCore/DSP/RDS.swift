import Foundation
import Accelerate

/// Decoded RDS (Radio Data System, EN 50067) information of the current station.
public struct RDSInfo: Equatable, Sendable {
    public var synced = false
    public var pi: UInt16?
    /// Programme Service name, 8 characters (unreceived positions are spaces).
    public var programService = ""
    public var radioText = ""
    public var pty: Int?
    public var trafficProgram = false
    public var trafficAnnouncement = false
    /// true = music, false = speech (group 0 MS flag).
    public var music: Bool?
    /// Clock time (group 4A) in UTC plus the broadcast local offset.
    public var clockTime: Date?
    public var clockOffsetMinutes = 0
    public var groupCount = 0
    /// Fraction of bad blocks over the recent window (0…1).
    public var blockErrorRate: Double = 0

    public init() {}

    public var hasData: Bool { pi != nil }
    public var piHex: String { pi.map { String(format: "%04X", $0) } ?? "" }
    public var ptyName: String {
        guard let pty, pty >= 0, pty < RDS.ptyNames.count else { return "" }
        return RDS.ptyNames[pty]
    }
    public var trimmedProgramService: String { programService.trimmingCharacters(in: .whitespaces) }
}

public enum RDS {
    public static let bitRate = 1187.5
    public static let carrier = 57_000.0

    enum Offset: Int, CaseIterable {
        case a, b, c, cPrime, d

        /// Position within a group (C and C' both sit in slot 2).
        var slot: Int {
            switch self {
            case .a: return 0
            case .b: return 1
            case .c, .cPrime: return 2
            case .d: return 3
            }
        }
    }

    static let poly: UInt32 = 0x5B9
    static let offsetWords: [UInt32] = [0x0FC, 0x198, 0x168, 0x350, 0x1B4]
    /// Syndrome of a valid 26-bit block carrying each offset word.
    static let syndromes: [UInt32] = offsetWords.map { syndrome($0, length: 26) }

    /// message(x)·x^10 mod g(x), g(x) = x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1.
    static func syndrome(_ message: UInt32, length: Int) -> UInt32 {
        var reg: UInt32 = 0
        for i in stride(from: length - 1, through: 0, by: -1) {
            reg = (reg << 1) | ((message >> UInt32(i)) & 1)
            if reg & (1 << 10) != 0 { reg ^= poly }
        }
        for _ in 0..<10 {
            reg <<= 1
            if reg & (1 << 10) != 0 { reg ^= poly }
        }
        return reg & 0x3FF
    }

    /// Longest error burst the decoder repairs (the code can correct bursts up to 5 bits).
    static let maxCorrectableBurst = 2

    /// Syndrome → error pattern for every burst up to `maxCorrectableBurst` bits within a 26-bit block.
    static let burstTable: [UInt32: UInt32] = {
        var table: [UInt32: UInt32] = [:]
        var ambiguous = Set<UInt32>()
        for length in 1...5 {
            let inner = length > 2 ? (0..<(1 << (length - 2))) : (0..<1)
            for middle in inner {
                let pattern: UInt32 = length == 1 ? 1 : (1 << UInt32(length - 1)) | (UInt32(middle) << 1) | 1
                for shift in 0...(26 - length) {
                    let e = pattern << UInt32(shift)
                    let s = syndrome(e, length: 26)
                    if let existing = table[s], existing != e { ambiguous.insert(s) } else { table[s] = e }
                }
            }
        }
        for s in ambiguous { table[s] = nil }
        return table
    }()

    static func burstLength(_ e: UInt32) -> Int {
        guard e != 0 else { return 0 }
        return 32 - e.leadingZeroBitCount - e.trailingZeroBitCount
    }

    /// Repairs a block with a short error burst; returns the data word when successful.
    static func correct(_ block: UInt32, _ offset: Offset) -> UInt16? {
        let s = syndrome(block, length: 26) ^ syndromes[offset.rawValue]
        guard let e = burstTable[s], burstLength(e) <= maxCorrectableBurst else { return nil }
        let fixed = block ^ e
        let data = UInt16(fixed >> 10)
        return checkword(data, offset) == fixed & 0x3FF ? data : nil
    }

    static func checkword(_ data: UInt16, _ offset: Offset) -> UInt32 {
        syndrome(UInt32(data), length: 16) ^ offsetWords[offset.rawValue]
    }

    static func block(_ data: UInt16, _ offset: Offset) -> UInt32 {
        UInt32(data) << 10 | checkword(data, offset)
    }

    /// European RDS programme types.
    public static let ptyNames = [
        "None", "News", "Current Affairs", "Information", "Sport", "Education", "Drama", "Culture",
        "Science", "Varied", "Pop Music", "Rock Music", "Easy Listening", "Light Classical", "Serious Classical",
        "Other Music", "Weather", "Finance", "Children's", "Social Affairs", "Religion", "Phone-in", "Travel",
        "Leisure", "Jazz", "Country", "National Music", "Oldies", "Folk Music", "Documentary", "Alarm Test", "Alarm",
    ]

    /// RDS G0 character set: ASCII range plus the common accented letters of 0x80–0x9F.
    private static let extended: [Character] = [
        "á", "à", "é", "è", "í", "ì", "ó", "ò", "ú", "ù", "Ñ", "Ç", "Ş", "β", "¡", "Ĳ",
        "â", "ä", "ê", "ë", "î", "ï", "ô", "ö", "û", "ü", "ñ", "ç", "ş", "ğ", "ı", "ĳ",
    ]

    static func character(_ byte: UInt8) -> Character {
        switch byte {
        case 0x20...0x7D: return Character(UnicodeScalar(byte))
        case 0x80...0x9F: return extended[Int(byte - 0x80)]
        default: return " "
        }
    }

    static func byte(_ ch: Character) -> UInt8 {
        if let a = ch.asciiValue, a >= 0x20, a <= 0x7D { return a }
        if let i = extended.firstIndex(of: ch) { return UInt8(0x80 + i) }
        return 0x20
    }
}

// MARK: - Group parsing

final class RDSParser {
    private(set) var info = RDSInfo()
    private var ps = [UInt8?](repeating: nil, count: 8)
    private var rt = [UInt8?](repeating: nil, count: 64)
    private var rtFlag = -1
    private var piCandidate: UInt16?

    func reset() {
        info = RDSInfo()
        ps = [UInt8?](repeating: nil, count: 8)
        rt = [UInt8?](repeating: nil, count: 64)
        rtFlag = -1
        piCandidate = nil
    }

    /// `blocks` = A, B, C (or C'), D; nil where the checkword failed.
    func handle(_ blocks: [UInt16?]) {
        if let a = blocks[0] { notePI(a) }
        guard let b = blocks[1] else { return }
        let type = Int(b >> 12)
        let versionB = (b >> 11) & 1 == 1
        if versionB, let c = blocks[2] { notePI(c) }
        info.trafficProgram = (b >> 10) & 1 == 1
        info.pty = Int((b >> 5) & 0x1F)
        info.groupCount += 1

        switch type {
        case 0:
            info.trafficAnnouncement = (b >> 4) & 1 == 1
            info.music = (b >> 3) & 1 == 1
            if let d = blocks[3] {
                let seg = Int(b & 3)
                ps[2 * seg] = UInt8(d >> 8)
                ps[2 * seg + 1] = UInt8(d & 0xFF)
                info.programService = String(ps.map { $0.map(RDS.character) ?? " " })
            }
        case 2:
            let flag = Int((b >> 4) & 1)
            if flag != rtFlag {
                rt = [UInt8?](repeating: nil, count: 64)
                rtFlag = flag
            }
            let seg = Int(b & 0xF)
            if versionB {
                if let d = blocks[3] {
                    rt[2 * seg] = UInt8(d >> 8)
                    rt[2 * seg + 1] = UInt8(d & 0xFF)
                }
            } else if let c = blocks[2], let d = blocks[3] {
                rt[4 * seg] = UInt8(c >> 8)
                rt[4 * seg + 1] = UInt8(c & 0xFF)
                rt[4 * seg + 2] = UInt8(d >> 8)
                rt[4 * seg + 3] = UInt8(d & 0xFF)
            }
            var text = ""
            for byte in rt {
                if byte == 0x0D { break }
                text.append(byte.map(RDS.character) ?? " ")
            }
            info.radioText = text.trimmingCharacters(in: .whitespaces)
        case 4 where !versionB:
            if let c = blocks[2], let d = blocks[3] { decodeClock(b, c, d) }
        default:
            break
        }
    }

    /// PI is accepted after it has been seen twice in a row, to reject false syncs.
    private func notePI(_ pi: UInt16) {
        if pi == piCandidate { info.pi = pi }
        piCandidate = pi
    }

    private func decodeClock(_ b: UInt16, _ c: UInt16, _ d: UInt16) {
        let mjd = Int(b & 3) << 15 | Int(c >> 1)
        let hour = Int(c & 1) << 4 | Int(d >> 12)
        let minute = Int((d >> 6) & 0x3F)
        let offsetHalfHours = Int(d & 0x1F) * ((d >> 5) & 1 == 1 ? -1 : 1)
        guard mjd > 15079, hour < 24, minute < 60 else { return }
        // MJD → calendar date (EN 50067 annex G).
        let yp = Int((Double(mjd) - 15078.2) / 365.25)
        let mp = Int((Double(mjd) - 14956.1 - Double(Int(Double(yp) * 365.25))) / 30.6001)
        let day = mjd - 14956 - Int(Double(yp) * 365.25) - Int(Double(mp) * 30.6001)
        let k = (mp == 14 || mp == 15) ? 1 : 0
        var comps = DateComponents()
        comps.year = 1900 + yp + k
        comps.month = mp - 1 - k * 12
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        info.clockTime = cal.date(from: comps)
        info.clockOffsetMinutes = offsetHalfHours * 30
    }
}

// MARK: - Demodulator

/// Recovers RDS from the FM multiplex signal: 57 kHz mix-down, Costas carrier loop, biphase matched
/// filter, Gardner symbol timing, differential decoding, block synchronisation and group parsing.
public final class RDSDecoder {
    public let inputRate: Double
    private let rate: Double
    private let samplesPerBit: Double
    private let lowpass: ComplexDecimator
    private let matched: RealDecimator

    private var ncoR = 1.0
    private var ncoI = 0.0
    private let ncoDR: Double
    private let ncoDI: Double
    private var mixI: [Float] = []
    private var mixQ: [Float] = []
    private var baseband: [Float] = []

    // Costas loop.
    private var phase: Float = 0
    private var freq: Float = 0
    private let alpha: Float
    private let beta: Float
    private let freqLimit: Float
    private var amplitude: Float = 1e-3

    // Symbol timing.
    private var history: [Float] = []
    private var next: Double
    private var lastSymbol: Float = 0
    private var symbolAmplitude: Float = 1e-3
    private var lastDecision = false

    // Block sync.
    private var register: UInt32 = 0
    private var bitIndex = 0
    private var synced = false
    private var presync: (bit: Int, offset: RDS.Offset)?
    private var bitsInBlock = 0
    private var slot = 0
    private var group = [UInt16?](repeating: nil, count: 4)
    private var recentBad: [Bool] = []
    private var lastSyncBit = 0

    private let parser = RDSParser()

    public init(inputRate: Double) {
        self.inputRate = inputRate
        let decimation = max(1, Int(inputRate / 19_000))
        rate = inputRate / Double(decimation)
        samplesPerBit = rate / RDS.bitRate
        lowpass = ComplexDecimator(factor: decimation,
                                   taps: FIR.lowpass(cutoff: 2_600 / inputRate, transition: 4_000 / inputRate, maxTaps: 1023))
        let bitLength = max(4, Int(samplesPerBit.rounded()))
        let half = bitLength / 2
        let taps = (0..<bitLength).map { Float($0 < half ? 1 : -1) / Float(bitLength) }
        matched = RealDecimator(factor: 1, taps: taps)
        ncoDR = cos(2 * .pi * RDS.carrier / inputRate)
        ncoDI = sin(2 * .pi * RDS.carrier / inputRate)
        let wn = Float(2 * Double.pi * 30 / rate)
        alpha = 2 * 0.707 * wn
        beta = wn * wn
        freqLimit = Float(2 * Double.pi * 60 / rate)
        next = samplesPerBit
    }

    public var info: RDSInfo {
        var i = parser.info
        i.synced = synced
        i.blockErrorRate = recentBad.isEmpty ? 1 : Double(recentBad.filter { $0 }.count) / Double(recentBad.count)
        return i
    }

    public func reset() {
        parser.reset()
        synced = false
        presync = nil
        recentBad.removeAll()
        group = [UInt16?](repeating: nil, count: 4)
        lastSyncBit = bitIndex
    }

    public func process(mpx: UnsafePointer<Float>, count: Int) {
        if mixI.count < count {
            mixI = [Float](repeating: 0, count: count)
            mixQ = mixI
        }
        // Mix 57 kHz down to baseband.
        var r = ncoR, im = ncoI
        for k in 0..<count {
            let x = Double(mpx[k])
            mixI[k] = Float(x * r)
            mixQ[k] = Float(-x * im)
            let nr = r * ncoDR - im * ncoDI
            im = r * ncoDI + im * ncoDR
            r = nr
        }
        let m = 1 / (r * r + im * im).squareRoot()
        ncoR = r * m
        ncoI = im * m

        let n = lowpass.process(i: mixI, q: mixQ, count: count)
        guard n > 0 else { return }
        if baseband.count < n { baseband = [Float](repeating: 0, count: n) }

        // Costas loop for BPSK: lock the carrier phase, keep the in-phase arm.
        let outI = lowpass.outI, outQ = lowpass.outQ
        var ph = phase, f = freq, amp = amplitude
        for k in 0..<n {
            let c = cosf(ph), s = sinf(ph)
            let i = outI[k] * c + outQ[k] * s
            let q = outQ[k] * c - outI[k] * s
            amp += ((i * i + q * q).squareRoot() - amp) * 0.002
            let norm = max(amp, 1e-9)
            let err = (i >= 0 ? q : -q) / norm
            f = max(-freqLimit, min(freqLimit, f + beta * err))
            ph += f + alpha * err
            if ph > .pi { ph -= 2 * .pi } else if ph < -.pi { ph += 2 * .pi }
            baseband[k] = i / norm
        }
        phase = ph
        freq = f
        amplitude = amp

        let mCount = matched.process(baseband, count: n)
        history.append(contentsOf: matched.output[0..<mCount])
        recoverSymbols()
    }

    private func sample(_ t: Double) -> Float {
        let i0 = Int(t)
        let frac = Float(t - Double(i0))
        return history[i0] + (history[i0 + 1] - history[i0]) * frac
    }

    /// Gardner timing recovery on the matched-filter output, one decision per bit.
    private func recoverSymbols() {
        let sps = samplesPerBit
        while next + 1 < Double(history.count) {
            let cur = sample(next)
            let mid = sample(next - sps / 2)
            symbolAmplitude += (abs(cur) - symbolAmplitude) * 0.01
            let a = max(symbolAmplitude, 1e-6)
            let err = (lastSymbol - cur) * mid / (a * a)
            lastSymbol = cur
            let decision = cur > 0
            handleBit(decision != lastDecision)
            lastDecision = decision
            next += sps + max(-sps / 8, min(sps / 8, 0.01 * sps * Double(err)))
        }
        // No sync for a while: the loop may sit on the half-bit point, so jump half a bit.
        if !synced && bitIndex - lastSyncBit > 26 * 60 {
            next += sps / 2
            lastSyncBit = bitIndex
        }
        let drop = max(0, Int(next - sps) - 2)
        if drop > 0 {
            history.removeFirst(min(drop, history.count))
            next -= Double(drop)
        }
    }

    private func handleBit(_ bit: Bool) {
        register = ((register << 1) | (bit ? 1 : 0)) & 0x3FF_FFFF
        bitIndex += 1
        guard synced else {
            searchSync()
            return
        }
        bitsInBlock += 1
        if bitsInBlock == 26 {
            bitsInBlock = 0
            processBlock()
        }
    }

    /// Two blocks with valid syndromes, a whole number of blocks apart and in the right order, give sync.
    private func searchSync() {
        let s = RDS.syndrome(register, length: 26)
        guard let index = RDS.syndromes.firstIndex(of: s), let offset = RDS.Offset(rawValue: index) else { return }
        if let p = presync {
            let distance = bitIndex - p.bit
            if distance % 26 == 0, distance <= 26 * 6, (p.offset.slot + distance / 26) % 4 == offset.slot {
                synced = true
                lastSyncBit = bitIndex
                recentBad.removeAll()
                group = [UInt16?](repeating: nil, count: 4)
                slot = offset.slot
                bitsInBlock = 0
                processBlock()
                return
            }
        }
        presync = (bitIndex, offset)
    }

    private func processBlock() {
        let data = UInt16(register >> 10)
        let check = register & 0x3FF
        let candidates: [RDS.Offset]
        switch slot {
        case 0: candidates = [.a]
        case 1: candidates = [.b]
        case 2: candidates = [.c, .cPrime]
        default: candidates = [.d]
        }
        var value: UInt16? = candidates.contains { RDS.checkword(data, $0) == check } ? data : nil
        let valid = value != nil
        if value == nil {
            value = candidates.lazy.compactMap { RDS.correct(self.register, $0) }.first
        }
        group[slot] = value
        recentBad.append(!valid)
        if recentBad.count > 50 { recentBad.removeFirst() }
        if valid { lastSyncBit = bitIndex }

        if slot == 3 {
            parser.handle(group)
            group = [UInt16?](repeating: nil, count: 4)
        }
        slot = (slot + 1) % 4

        if recentBad.count >= 20 && Double(recentBad.filter { $0 }.count) / Double(recentBad.count) > 0.7 {
            synced = false
            presync = nil
        }
    }
}

// MARK: - Encoder (demo generator and tests)

enum RDSEncoder {
    /// Differentially encoded bit stream for a repeating cycle of 0A (PS) and 2A (RadioText) groups.
    static func bitstream(pi: UInt16, ps: String, radioText: String, pty: Int, tp: Bool = true) -> [Bool] {
        let psBytes = Array(ps.padding(toLength: 8, withPad: " ", startingAt: 0)).map(RDS.byte)
        var rtChars = Array(radioText.prefix(64))
        if rtChars.count < 64 { rtChars.append("\r") }
        let rtBytes = rtChars.map { $0 == "\r" ? 0x0D : RDS.byte($0) }
            + [UInt8](repeating: 0x20, count: max(0, 64 - rtChars.count))
        let segments = (rtBytes.count + 3) / 4
        let tpBit: UInt16 = tp ? 1 << 10 : 0
        let ptyBits = UInt16(pty & 0x1F) << 5

        var blocks: [UInt32] = []
        func group(_ b: UInt16, _ c: UInt16, _ d: UInt16) {
            blocks += [RDS.block(pi, .a), RDS.block(b, .b), RDS.block(c, .c), RDS.block(d, .d)]
        }
        for i in 0..<max(segments, 4) {
            let psSeg = i % 4
            group(tpBit | ptyBits | (1 << 3) | UInt16(psSeg), 0xE0CD,
                  UInt16(psBytes[2 * psSeg]) << 8 | UInt16(psBytes[2 * psSeg + 1]))
            let rtSeg = i % segments
            let at = 4 * rtSeg
            func byte(_ k: Int) -> UInt16 { UInt16(k < rtBytes.count ? rtBytes[k] : 0x20) }
            group(2 << 12 | tpBit | ptyBits | UInt16(rtSeg), byte(at) << 8 | byte(at + 1), byte(at + 2) << 8 | byte(at + 3))
        }

        var bits: [Bool] = []
        var previous = false
        for block in blocks {
            for i in stride(from: 25, through: 0, by: -1) {
                let bit = (block >> UInt32(i)) & 1 == 1
                previous = previous != bit
                bits.append(previous)
            }
        }
        return bits
    }
}
