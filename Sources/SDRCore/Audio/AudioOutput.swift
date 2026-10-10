import Foundation
import AVFoundation

/// Plays the demodulated audio through the default output device.
///
/// When the output device changes (another default device, AirPlay, headphones), AVAudioEngine
/// stops itself and posts `AVAudioEngineConfigurationChange`; playback is then restarted on the new device.
public final class AudioOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    public let ring: AudioRingBuffer
    public private(set) var sampleRate: Double = 0

    public init(ring: AudioRingBuffer) {
        self.ring = ring
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func restartAfterConfigurationChange() {
        // Only restart when playback is meant to be running (stop() clears sourceNode).
        guard sourceNode != nil, !engine.isRunning else { return }
        do {
            try start(sampleRate: sampleRate)
        } catch {
            NSLog("Kymara: restarting audio after a device change failed: \(error)")
        }
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
