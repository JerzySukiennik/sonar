// Sonar: ties audio, tracking and mapping together and publishes what the screen shows.
import AVFoundation
import SwiftUI
import simd

final class Recorder {
    private var handle: FileHandle?
    private var written = 0

    func open(fs: Double, n: Int) {
        close()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("last.sonarlog")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        var header = Data("SONARLOG".utf8)
        append(&header, fs)
        append(&header, Int32(n))
        append(&header, Int32(0))
        handle?.write(header)
        written = 0
    }

    func write(time: Double, lag: Double, transform: simd_float4x4?, samples: [Int16]) {
        guard let handle, written < 2400 else { return }
        var data = Data(capacity: 96 + samples.count * 2)
        append(&data, time)
        append(&data, lag)
        append(&data, Int32(transform == nil ? 0 : 1))
        append(&data, Int32(samples.count))
        let m = transform ?? matrix_identity_float4x4
        for column in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            for i in 0..<4 { append(&data, column[i]) }
        }
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        handle.write(data)
        written += 1
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func append<T>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}

final class SonarModel: ObservableObject {
    @Published var running = false
    @Published var status = "Ready"
    @Published var detail = ""
    @Published var scope: [Float] = []
    @Published var pings = 0
    @Published var dark = true { didSet { renderer.dim(dark ? 1 : 0.5) } }
    @Published var sharpness = 0.4 { didSet { let c = Float(sharpness); work.async { self.cut = c; self.publishMap() } } }
    let renderer = MapRenderer()
    let tracker = Tracker()
    var startTracking: (() -> Void)?
    var verbose = false
    private let audio = SonarAudio()
    private let mapper = Mapper()
    private let recorder = Recorder()
    private let work = DispatchQueue(label: "fun.gzowo.sonar.map", qos: .userInitiated)
    private var trail: [SIMD3<Float>] = []
    private var frames = 0
    private var cut: Float = 0.4

    init() {
        audio.onFrame = { [weak self] frame in
            self?.work.asyncAfter(deadline: .now() + 0.12) { self?.ingest(frame) }
        }
    }

    func toggle() {
        if running { stop() } else { start() }
    }

    func start() {
        guard !running else { return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.status = "Microphone is off. Allow it in Settings."; return }
                self.startTracking?()
                self.startTracking = nil
                self.renderer.dim(self.dark ? 1 : 0.5)
                do {
                    try self.audio.start()
                } catch {
                    self.status = "Audio did not start"
                    self.detail = error.localizedDescription
                    return
                }
                let fs = self.audio.sampleRate, n = self.audio.period
                self.work.async { self.recorder.open(fs: fs, n: n) }
                self.running = true
                self.status = "Listening"
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    func stop() {
        audio.stop()
        work.async { self.recorder.close() }
        running = false
        status = pings > 0 ? "Paused · \(pings) pings" : "Ready"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clear() {
        work.async {
            self.mapper.reset(around: self.trail.last ?? SIMD3<Float>(repeating: 0))
            self.trail = []
            DispatchQueue.main.async {
                self.pings = 0
                self.renderer.show(points: [], values: [])
                self.renderer.show(path: [])
            }
        }
    }

    private func ingest(_ frame: SonarAudio.Frame) {
        frames += 1
        let echo = frame.echo
        let pose = tracker.pose(at: frame.time)
        recorder.write(time: frame.time, lag: echo.lag, transform: pose?.transform, samples: frame.samples)
        var placed = false
        if let pose, echo.ready {
            if !mapper.started { mapper.reset(around: pose.position) }
            placed = mapper.add(position: pose.position, axis: pose.axis, profile: echo.profile, binSize: Float(audio.binSize),
                                rMin: Float(EchoProcessor.rMin), rMax: Float(EchoProcessor.rMax))
            if placed { trail.append(pose.position) }
        }
        if placed && mapper.count % 8 == 0 { publishMap() }
        if verbose && frames % 6 == 0 {
            print(String(format: "frame %d lag %.3f direct %.4f snr %.1f peak %.3f ready %d", frames, echo.lag, echo.direct, echo.snr, echo.peak, echo.ready ? 1 : 0))
        }
        guard frames % 2 == 0 else { return }
        let count = mapper.count, tracking = tracker.isTracking
        let text = audio.route + String(format: " · direct %.0f dB", echo.snr)
        DispatchQueue.main.async {
            guard self.running else { return }
            self.scope = echo.scope
            self.pings = count
            self.detail = text
            if echo.peak > 0.95 { self.status = "Too loud. Turn the volume down." }
            else if echo.snr < 25 { self.status = "No sound path. Turn the volume up." }
            else if !tracking { self.status = "Finding position. Move slowly." }
            else { self.status = "Scanning · \(count) pings" }
        }
    }

    private func publishMap() {
        let map = mapper.points(threshold: cut)
        let path = trail
        DispatchQueue.main.async {
            self.renderer.show(points: map.positions, values: map.values)
            self.renderer.show(path: path)
        }
    }

    func simulate() {
        work.async {
            let walls: [(axis: Int, at: Float)] = [(0, -2.0), (0, 2.4), (1, -1.3), (1, 1.2), (2, -1.6), (2, 2.8)]
            let bin = Float(EchoProcessor.speed / 96000), bins = Int(Float(EchoProcessor.rMax) / bin) + 2
            self.mapper.reset(around: SIMD3<Float>(repeating: 0))
            var seed: UInt64 = 42
            var profile = [Float](repeating: 0, count: bins)
            for step in 0..<420 {
                let t = Float(step) * 0.085
                let p = SIMD3<Float>(0.55 * sin(0.9 * t) + 0.25 * sin(2.3 * t), 0.35 * sin(1.3 * t + 1), 0.5 * cos(0.7 * t) + 0.2 * sin(1.9 * t))
                let axis = simd_normalize(SIMD3<Float>(cos(0.5 * t), 0.6 * sin(0.8 * t), sin(0.5 * t)))
                for k in 0..<bins { profile[k] = 0 }
                for wall in walls {
                    var normal = SIMD3<Float>(repeating: 0)
                    normal[wall.axis] = wall.at > p[wall.axis] ? 1 : -1
                    let beam = 0.5 + 0.5 * simd_dot(axis, normal)
                    let amp = 0.01 * (0.25 + 0.75 * beam * beam), center = abs(wall.at - p[wall.axis]) / bin
                    for k in max(0, Int(center) - 8)...min(bins - 1, Int(center) + 8) {
                        let x = (Float(k) - center) / 3
                        profile[k] += amp * exp(-x * x)
                    }
                }
                for _ in 0..<6 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    profile[140 + Int((seed >> 33) % UInt64(bins - 140))] += 0.004
                }
                if self.mapper.add(position: p, axis: axis, profile: profile, binSize: bin, rMin: Float(EchoProcessor.rMin), rMax: Float(EchoProcessor.rMax)) {
                    self.trail.append(p)
                }
            }
            let map = self.mapper.points(threshold: self.cut)
            let onWall = map.positions.filter { q in walls.contains { abs(q[$0.axis] - $0.at) < 0.08 } }.count
            print("selftest pings \(self.mapper.count) points \(map.positions.count) on a wall \(onWall)")
            let scope = profile.enumerated().reduce(into: [Float](repeating: -60, count: 160)) { out, item in
                let s = item.offset * 160 / bins
                out[s] = max(out[s], 20 * log10(item.element + 1e-3))
            }
            let count = self.mapper.count
            DispatchQueue.main.async {
                self.pings = count
                self.scope = scope
                self.status = "Scanning · \(count) pings"
                self.detail = "48 kHz · Speaker to bottom mic · direct 64 dB"
            }
            self.publishMap()
        }
    }
}
