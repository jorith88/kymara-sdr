import Foundation
import AVFoundation

/// Plays the demodulated audio through the default output device.
public final class AudioOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    public let ring: AudioRingBuffer
    public private(set) var sampleRate: Double = 0

    public init(ring: AudioRingBuffer) {
        self.ring = ring
    }

    public func start(sampleRate: Double) throws {
        stop()
        self.sampleRate = sampleRate
        ring.reset(sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(left: l, right: r, count: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        if engine.isRunning { engine.stop() }
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
    }
}
