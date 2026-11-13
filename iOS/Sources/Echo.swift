// Sonar: turns one recorded chirp period into a range profile of moving echoes, locked to the direct speaker-to-microphone path.
import Accelerate
import Foundation

struct Echo {
    var lag: Double
    var direct: Float
    var snr: Float
    var peak: Float
    var ready: Bool
    var profile: [Float]
    var scope: [Float]
}

final class EchoProcessor {
    static let speed = 343.0
    static let rMin = 0.5
    static let rMax = 5.0
    let pc: PulseCompressor
    let binSize: Double
    let bins: Int
    private var taus: [Double] = []
    private var tau = 0.0
    private var jumps = 0
    private var seen = 0
    private var ref: Float = 0
    private var tail: Float?
    private var bgR: [Float]
    private var bgI: [Float]

    init(fs: Double) {
        pc = PulseCompressor(fs: fs)
        binSize = EchoProcessor.speed / (2 * fs)
        bins = min(pc.n / 2 - 64, Int(EchoProcessor.rMax / binSize) + 2)
        bgR = [Float](repeating: 0, count: bins)
        bgI = [Float](repeating: 0, count: bins)
    }

    func gainChanged() {
        seen = 0
        ref = 0
        tail = nil
    }

    func reset() {
        taus = []
        jumps = 0
        gainChanged()
    }

    func process(_ frame: UnsafePointer<Float>) -> Echo? {
        let n = pc.n
        var peak: Float = 0
        vDSP_maxmgv(frame, 1, &peak, vDSP_Length(n))
        pc.load(frame)
        pc.impulse(shift: 0)
        var p = 0
        var side = (0.0, 0.0, 0.0)
        pc.outR.withUnsafeBufferPointer { r in
            pc.outI.withUnsafeBufferPointer { i in
                var best: Float = 0
                for k in 0..<n {
                    let e = r[k] * r[k] + i[k] * i[k]
                    if e > best { best = e; p = k }
                }
                let before = (p + n - 1) % n, after = (p + 1) % n
                side = (Double(hypot(r[before], i[before])), Double(hypot(r[p], i[p])), Double(hypot(r[after], i[after])))
            }
        }
        let den = side.0 - 2 * side.1 + side.2
        let tauNow = Double(p) + (den != 0 ? 0.5 * (side.0 - side.2) / den : 0)
        if taus.count < 7 {
            taus.append(tauNow)
            tau = taus.sorted()[taus.count / 2]
            seen = 0
        } else {
            var d = tauNow - tau
            if d > Double(n) / 2 { d -= Double(n) } else if d < -Double(n) / 2 { d += Double(n) }
            if abs(d) <= 2 {
                jumps = 0
                tau += 0.05 * max(-0.1, min(0.1, d))
            } else {
                jumps += 1
                if jumps >= 6 { taus = [tauNow]; tau = tauNow; jumps = 0; seen = 0 }
            }
        }
        pc.impulse(shift: tau)
        let first = Int(EchoProcessor.rMin / binSize)
        var result: Echo?
        pc.outR.withUnsafeBufferPointer { hr in
            pc.outI.withUnsafeBufferPointer { hi in
                var t: Float = 0
                for k in bins..<(n / 2) { t += hr[k] * hr[k] + hi[k] * hi[k] }
                let tailDb = 10 * log10(t / Float(n / 2 - bins) + 1e-30)
                let burst = tail != nil && tailDb > tail! + 8
                tail = tail == nil ? tailDb : tail! + (burst ? 0.05 : 0.2) * (tailDb - tail!)
                if burst { return }
                let h0 = hypot(hr[0], hi[0])
                ref = ref > 0 ? ref + 0.1 * (h0 - ref) : h0
                let aBg: Float = seen < 4 ? 1 / Float(seen + 1) : 0.04
                var profile = [Float](repeating: 0, count: bins)
                var scope = [Float](repeating: -140, count: 160)
                for k in 0..<bins {
                    let dr = hr[k] - bgR[k], di = hi[k] - bgI[k]
                    bgR[k] += aBg * dr
                    bgI[k] += aBg * di
                    let range = Float(Double(k) * binSize)
                    if k >= first { profile[k] = hypot(dr, di) / ref * range }
                    let v = 20 * log10(hypot(hr[k], hi[k]) / ref + 1e-9) + 20 * log10(max(range, 0.1))
                    let s = k * 160 / bins
                    if v > scope[s] { scope[s] = v }
                }
                seen += 1
                let ready = seen > 10
                if ready {
                    var sorted = Array(profile[first...])
                    sorted.sort()
                    let gate = 3 * sorted[sorted.count / 2]
                    for k in first..<bins { profile[k] = max(0, profile[k] - gate) }
                } else {
                    for k in 0..<bins { profile[k] = 0 }
                }
                result = Echo(lag: tau, direct: h0, snr: 20 * log10(h0 + 1e-30) - tailDb, peak: peak, ready: ready, profile: profile, scope: scope)
            }
        }
        return result
    }
}
