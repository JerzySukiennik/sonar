// Sonar: ties audio, tracking and plane finding together and publishes what the screen shows.
import AVFoundation
import SwiftUI
import simd

final class Recorder {
    private var handle: FileHandle?
    private var written = 0
    private var name = ""
    private var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func open(fs: Double, n: Int) {
        close()
        let files = FileManager.default
        let old = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("scan-") || $0.hasPrefix("last.") }.sorted()
        let logs = old.filter { $0.hasSuffix(".sonarlog") }
        for file in old where file.hasPrefix("last.") || logs.dropLast(4).contains(where: { file.hasPrefix($0.dropLast(9)) }) {
            try? files.removeItem(at: folder.appendingPathComponent(file))
        }
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        name = "scan-" + format.string(from: Date())
        let url = folder.appendingPathComponent(name + ".sonarlog")
        files.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        var header = Data("SONARLOG".utf8)
        append(&header, fs)
        append(&header, Int32(n))
        append(&header, Int32(0))
        handle?.write(header)
        written = 0
    }

    func note(_ text: String) {
        guard !name.isEmpty else { return }
        try? text.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    func write(time: Double, lag: Double, state: Int32, transform: simd_float4x4?, samples: [Int16]) {
        guard let handle, written < 3000 else { return }
        var data = Data(capacity: 96 + samples.count * 2)
        append(&data, time)
        append(&data, lag)
        append(&data, transform == nil ? min(state, 0) : Int32(1))
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
    @Published var coverage = 0.0
    @Published var surfaces = 0
    @Published var dark = true { didSet { renderer.dim(dark ? 1 : 0.5) } }
    let renderer = MapRenderer()
    let tracker = Tracker()
    var startTracking: (() -> Void)?
    var verbose = false
    private let audio = SonarAudio()
    private let finder = PlaneFinder()
    private let recorder = Recorder()
    private let work = DispatchQueue(label: "fun.gzowo.sonar.map", qos: .userInitiated)
    private var frames = 0
    private var fresh = true
    private var restarts = 0
    private var notice = ""
    private var noticeUntil = 0.0
    private var lastTime = 0.0
    private var lastPlace = SIMD3<Float>(repeating: 0)

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
                self.work.async {
                    self.recorder.open(fs: fs, n: n)
                    self.frames = 0
                }
                self.running = true
                self.status = "Listening"
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    func stop() {
        audio.stop()
        let note = audio.route + "\n" + audio.note + "\n" + tracker.summary + "\n"
        work.async {
            self.recorder.note(note + "pings \(self.finder.pings), surfaces \(self.finder.planes.count), coverage \(self.finder.coverage), restarts \(self.restarts)\n")
            self.recorder.close()
        }
        running = false
        status = pings > 0 ? "Paused · \(pings) pings" : "Ready"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clear() {
        work.async {
            self.fresh = true
            self.finder.reset(around: self.finder.trail.last ?? self.finder.center)
            DispatchQueue.main.async {
                self.pings = 0
                self.coverage = 0
                self.surfaces = 0
                self.renderer.show(points: [], values: [])
                self.renderer.show(path: [])
            }
        }
    }

    private func ingest(_ frame: SonarAudio.Frame) {
        frames += 1
        let echo = frame.echo
        let pose = tracker.pose(at: frame.time)
        let state = tracker.state
        recorder.write(time: frame.time, lag: echo.lag, state: state, transform: pose?.transform, samples: frame.samples)
        if frames == 1 { recorder.note(audio.route + "\n" + audio.note + "\n") }
        if let pose, echo.ready {
            let gap = frame.time - lastTime, moved = simd_distance(pose.position, lastPlace)
            let jumped = !fresh && (moved > (gap < 0.5 ? 0.25 : 0.6) || simd_distance(pose.position, finder.center) > 3)
            if jumped {
                restarts += 1
                notice = "Camera lost its place. Map restarted."
                noticeUntil = frame.time + 4
            }
            if fresh || jumped {
                finder.reset(around: pose.position)
                fresh = false
                publishMap()
            }
            lastTime = frame.time
            lastPlace = pose.position
            if finder.add(position: pose.position, profile: echo.profile, rMin: Float(EchoProcessor.rMin)), finder.pings % 6 == 0 {
                finder.detect()
                publishMap()
            }
        }
        if verbose && frames % 6 == 0 {
            print(String(format: "frame %d lag %.3f direct %.4f snr %.1f peak %.3f ready %d", frames, echo.lag, echo.direct, echo.snr, echo.peak, echo.ready ? 1 : 0))
        }
        guard frames % 2 == 0 else { return }
        let count = finder.pings, cover = Double(finder.coverage), found = finder.planes.count
        let lost = state == 1 ? "" : (Tracker.reasons[state] ?? "Finding position")
        let flash = frame.time < noticeUntil ? notice : ""
        let text = audio.route + String(format: " · direct %.0f dB", echo.snr)
        DispatchQueue.main.async {
            guard self.running else { return }
            self.scope = echo.scope
            self.pings = count
            self.coverage = cover
            self.surfaces = found
            self.detail = text
            if echo.peak > 0.95 { self.status = "Too loud. Turn the volume down." }
            else if echo.snr < 25 || echo.direct < 0.002 { self.status = "Too quiet. Turn the volume up." }
            else if !lost.isEmpty { self.status = lost }
            else if !flash.isEmpty { self.status = flash }
            else if cover < 1 { self.status = "Move more · \(Int(cover * 100))%" }
            else { self.status = "\(found) surfaces · \(count) pings" }
        }
    }

    private func publishMap() {
        let map = finder.points()
        let path = finder.trail
        DispatchQueue.main.async {
            self.renderer.show(points: map.positions, values: map.values)
            self.renderer.show(path: path)
        }
    }

    private func report(_ title: String) {
        print("\(title): pings \(finder.pings) coverage \(String(format: "%.2f", finder.coverage)) best over chance \(String(format: "%.2f", finder.ratio * PlaneFinder.margin)) surfaces \(finder.planes.count)")
        let here = finder.trail.last ?? finder.center
        for plane in finder.planes {
            print(String(format: "  normal %+.2f %+.2f %+.2f  distance %.2f m  over chance %.2f  contrast %.1f", plane.normal.x, plane.normal.y, plane.normal.z,
                         finder.range(of: plane, from: here), plane.strength * PlaneFinder.margin, plane.contrast))
        }
    }

    func simulate() {
        work.async {
            let walls: [(axis: Int, at: Float)] = [(0, -2.0), (0, 2.4), (1, -1.3), (1, 1.2), (2, -1.6), (2, 2.8)]
            let cells = Int((EchoProcessor.rMax - EchoProcessor.rMin) / EchoProcessor.step), step = Float(EchoProcessor.step), rMin = Float(EchoProcessor.rMin)
            self.finder.reset(around: SIMD3<Float>(repeating: 0))
            var seed: UInt64 = 42
            var profile = [Float](repeating: 0, count: cells)
            for tick in 0..<360 {
                let t = Float(tick) * 0.085
                let p = SIMD3<Float>(0.22 * sin(0.9 * t) + 0.1 * sin(2.3 * t), 0.2 * sin(1.3 * t + 1), 0.24 * cos(0.7 * t) + 0.08 * sin(1.9 * t))
                for c in 0..<cells { profile[c] = 0 }
                for wall in walls {
                    let center = (abs(wall.at - p[wall.axis]) - rMin) / step
                    for c in max(0, Int(center) - 4)...min(cells - 1, Int(center) + 4) {
                        let x = (Float(c) - center) / 1.2
                        profile[c] += 0.01 * exp(-x * x)
                    }
                }
                for _ in 0..<10 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    profile[Int((seed >> 33) % UInt64(cells))] += 0.006
                }
                profile[6] += 0.02
                profile[14] += 0.015
                _ = self.finder.add(position: p, profile: profile, rMin: rMin)
            }
            self.finder.detect()
            self.report("selftest (true walls at 2.0 2.4 1.3 1.2 1.6 2.8 m along -x +x -y +y -z +z)")
            let scope = profile.enumerated().reduce(into: [Float](repeating: -60, count: 160)) { out, item in
                let s = 26 + item.offset * 134 / cells
                out[s] = max(out[s], 20 * log10(item.element + 1e-3))
            }
            let count = self.finder.pings, found = self.finder.planes.count
            DispatchQueue.main.async {
                self.pings = count
                self.coverage = 1
                self.surfaces = found
                self.scope = scope
                self.status = "\(found) surfaces · \(count) pings"
                self.detail = "48 kHz · Speaker to mic · direct 64 dB"
            }
            self.publishMap()
        }
    }

    func replay(_ path: String) {
        work.async {
            guard let raw = FileManager.default.contents(atPath: path), raw.count > 24, String(data: raw.prefix(8), encoding: .utf8) == "SONARLOG" else {
                print("replay: cannot read \(path)")
                return
            }
            let fs = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Double.self) }
            let n = Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: Int32.self) })
            let proc = EchoProcessor(fs: fs)
            var offset = 24, total = 0, used = 0, restarts = 0
            var lastTime = 0.0, lastPlace = SIMD3<Float>(repeating: 0)
            var shuffled: [(SIMD3<Float>, [Float])] = []
            let shuffle = ProcessInfo.processInfo.arguments.contains("--shuffle")
            var frame = [Float](repeating: 0, count: n)
            var last: Echo?
            var fresh = true
            while offset + 88 + n * 2 <= raw.count {
                let has = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: Int32.self) }
                let time = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Double.self) }
                var columns = [SIMD4<Float>](repeating: SIMD4<Float>(repeating: 0), count: 4)
                raw.withUnsafeBytes { bytes in
                    for c in 0..<4 {
                        for r in 0..<4 { columns[c][r] = bytes.loadUnaligned(fromByteOffset: offset + 24 + (c * 4 + r) * 4, as: Float.self) }
                    }
                    for i in 0..<n { frame[i] = Float(bytes.loadUnaligned(fromByteOffset: offset + 88 + i * 2, as: Int16.self)) / 32767 }
                }
                offset += 88 + n * 2
                total += 1
                guard let echo = frame.withUnsafeBufferPointer({ proc.process($0.baseAddress!) }) else { continue }
                last = echo
                guard has == 1, echo.ready else { continue }
                let m = simd_float4x4(columns[0], columns[1], columns[2], columns[3])
                let p = m * Tracker.speakerOffset
                let position = SIMD3<Float>(p.x, p.y, p.z)
                if shuffle {
                    shuffled.append((position, echo.profile))
                    continue
                }
                let gap = time - lastTime, moved = simd_distance(position, lastPlace)
                let jumped = !fresh && (moved > (gap < 0.5 ? 0.25 : 0.6) || simd_distance(position, self.finder.center) > 3)
                if jumped {
                    restarts += 1
                    self.finder.detect()
                    self.report(String(format: "replay, map before restart %d at %.1f s", restarts, time))
                }
                if fresh || jumped {
                    self.finder.reset(around: position)
                    fresh = false
                }
                lastTime = time
                lastPlace = position
                if self.finder.add(position: position, profile: echo.profile, rMin: Float(EchoProcessor.rMin)) { used += 1 }
            }
            if shuffle, let first = shuffled.first {
                self.finder.reset(around: first.0)
                var seed: UInt64 = 99
                var order = Array(shuffled.indices)
                for i in stride(from: order.count - 1, to: 0, by: -1) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    order.swapAt(i, Int((seed >> 33) % UInt64(i + 1)))
                }
                var previous = SIMD3<Float>(repeating: .infinity)
                for (i, item) in shuffled.enumerated() where simd_distance(item.0, previous) >= 0.015 {
                    previous = item.0
                    if self.finder.add(position: item.0 + SIMD3<Float>(repeating: 1e-4) * Float(i % 2), profile: shuffled[order[i]].1, rMin: Float(EchoProcessor.rMin)) { used += 1 }
                }
            }
            self.finder.detect()
            if let last {
                print(String(format: "replay: frames %d, used %d, direct lag %.2f, direct to floor %.1f dB, mic peak %.3f", total, used, last.lag, last.snr, last.peak))
            }
            self.report("replay")
            let count = self.finder.pings, found = self.finder.planes.count, cover = Double(self.finder.coverage), scope = last?.scope ?? []
            DispatchQueue.main.async {
                self.pings = count
                self.coverage = cover
                self.surfaces = found
                self.scope = scope
                self.status = cover < 1 ? "Move more · \(Int(cover * 100))%" : "\(found) surfaces · \(count) pings"
            }
            self.publishMap()
        }
    }
}
