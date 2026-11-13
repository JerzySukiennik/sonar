// Sonar: plays the looping chirp and cuts the microphone stream into periods that share its sample clock.
import AVFoundation

final class SonarAudio {
    struct Frame {
        let time: TimeInterval
        let echo: Echo
        let samples: [Int16]
    }

    enum Failure: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input" }
    }

    var onFrame: ((Frame) -> Void)?
    private(set) var route = ""
    private(set) var note = ""
    private(set) var sampleRate = 48000.0
    private(set) var period = 4096
    private(set) var binSize = 343.0 / 96000
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var processor: EchoProcessor?
    private var buffer: [Float] = []
    private var fill = 0
    private var startSample: Int64 = 0
    private var nextSample: Int64 = -1
    private var counter: Int64 = 0
    private var latency = 0.0
    private var hot = 0
    private var calib = 0
    private var levelA: Float = 0
    private var levelB: Float = 0

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        let source = session.currentRoute.inputs.first?.selectedDataSource ?? session.inputDataSource
        let micName = (source?.dataSourceName ?? "mic").lowercased() + " mic"
        latency = session.inputLatency
        note = ""
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Failure.noInput }
        sampleRate = inFormat.sampleRate
        let proc = EchoProcessor(fs: sampleRate)
        processor = proc
        period = proc.pc.n
        binSize = proc.binSize
        buffer = [Float](repeating: 0, count: period)
        fill = 0; nextSample = -1; counter = 0; hot = 0; calib = 0; levelA = 0; levelB = 0
        let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let loop = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(period))!
        loop.frameLength = AVAudioFrameCount(period)
        let out = loop.floatChannelData![0]
        for i in 0..<period { out[i] = proc.pc.wave[i] * 0.8 }
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, when in
            self?.consume(buf, when)
        }
        engine.prepare()
        try engine.start()
        player.volume = 1
        player.pan = -1
        player.scheduleBuffer(loop, at: nil, options: .loops)
        player.play()
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let port = session.currentRoute.outputs.first?.portType.rawValue ?? "output"
        route = "\(Int(sampleRate / 1000)) kHz · \(port) to \(micName)" + (outRate != sampleRate ? " · rate mismatch" : "")
    }

    func stop() {
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processor = nil
    }

    private func consume(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard let proc = processor, let data = buf.floatChannelData?[0] else { return }
        let count = Int(buf.frameLength)
        let first = when.isSampleTimeValid ? when.sampleTime : counter
        counter = first + Int64(count)
        if nextSample >= 0 && first != nextSample {
            fill = 0
            proc.reset()
        }
        nextSample = first + Int64(count)
        let hostAtFirst = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : ProcessInfo.processInfo.systemUptime
        var i = 0
        while i < count {
            if fill == 0 { startSample = first + Int64(i) }
            let take = min(period - fill, count - i)
            buffer.withUnsafeMutableBufferPointer { ($0.baseAddress! + fill).update(from: data + i, count: take) }
            fill += take
            i += take
            if fill == period {
                fill = 0
                handle(at: hostAtFirst + Double(startSample - first) / sampleRate, proc)
            }
        }
    }

    private func handle(at frameTime: TimeInterval, _ proc: EchoProcessor) {
        guard let echo = buffer.withUnsafeBufferPointer({ proc.process($0.baseAddress!) }) else { return }
        if calib < 24 {
            if calib >= 7 && calib < 12 { levelA += echo.tail / 5 }
            if calib >= 19 { levelB += echo.tail / 5 }
            calib += 1
            if calib == 12 { player.pan = 1; proc.gainChanged() }
            if calib == 24 {
                player.pan = levelA > levelB + 3 ? -1 : (levelB > levelA + 3 ? 1 : 0)
                proc.reset()
                note = String(format: "pan %.0f, room level with left %.1f dB, with right %.1f dB, chirp %d samples %.0f-%.0f Hz", player.pan, levelA, levelB,
                              SonarConfig.chirp, SonarConfig.f1, SonarConfig.f2)
            }
            return
        }
        hot = echo.peak > 0.6 ? hot + 1 : 0
        if hot >= 3 && player.volume > 0.05 {
            hot = 0
            player.volume = max(0.05, player.volume * 0.8)
            proc.gainChanged()
        }
        if note.hasPrefix("pan") && !note.contains("volume") { note += String(format: ", volume %.2f, mic peak %.3f", player.volume, echo.peak) }
        let samples = buffer.map { Int16(max(-1, min(1, $0)) * 32767) }
        onFrame?(Frame(time: frameTime + echo.lag / sampleRate - latency, echo: echo, samples: samples))
    }
}
