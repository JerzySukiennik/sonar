// Sonar: chirp synthesis and pulse compression of one recorded period into a complex impulse response.
import Accelerate
import Foundation

final class PulseCompressor {
    let n: Int
    let fs: Double
    let wave: [Float]
    let resolution: Double
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let kLo: Int
    private let kHi: Int
    private var gr: [Float]
    private var gi: [Float]
    private var yr: [Float]
    private var yi: [Float]
    private var hr: [Float]
    private var hi: [Float]
    private(set) var outR: [Float]
    private(set) var outI: [Float]

    init(fs: Double, n: Int = 4096, chirp: Int = 1024, f1: Double = 3000, f2: Double = 18000) {
        self.n = n
        self.fs = fs
        log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        let top = min(f2, fs / 2 - 1500)
        resolution = 343 / (top - f1)
        var w = [Float](repeating: 0, count: n)
        let rate = (top - f1) / (Double(chirp) / fs), taper = 0.08 * Double(chirp)
        for i in 0..<chirp {
            let t = Double(i) / fs, edge = Double(min(i, chirp - 1 - i)) / taper
            let a = edge >= 1 ? 1 : 0.5 - 0.5 * cos(Double.pi * edge)
            w[i] = Float(a * sin(2 * Double.pi * (f1 * t + 0.5 * rate * t * t)))
        }
        wave = w
        kLo = Int((f1 * Double(n) / fs).rounded())
        kHi = Int((top * Double(n) / fs).rounded())
        let zeros = [Float](repeating: 0, count: n)
        gr = zeros; gi = zeros; yr = zeros; yi = zeros; hr = zeros; hi = zeros; outR = zeros; outI = zeros
        var xr = w, xi = zeros
        transform(&xr, &xi, inverse: false)
        var pmax: Float = 0
        for k in kLo...kHi { pmax = max(pmax, xr[k] * xr[k] + xi[k] * xi[k]) }
        for k in kLo...kHi {
            let win = Float(1 - cos(2 * Double.pi * Double(k - kLo) / Double(kHi - kLo)))
            let d = xr[k] * xr[k] + xi[k] * xi[k] + pmax * 1e-3
            gr[k] = xr[k] / d * win
            gi[k] = -xi[k] / d * win
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    private func transform(_ r: inout [Float], _ i: inout [Float], inverse: Bool) {
        r.withUnsafeMutableBufferPointer { rp in
            i.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
            }
        }
    }

    func load(_ frame: UnsafePointer<Float>) {
        yr.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: frame, count: n) }
        vDSP_vclr(&yi, 1, vDSP_Length(n))
        transform(&yr, &yi, inverse: false)
        for k in kLo...kHi {
            hr[k] = yr[k] * gr[k] - yi[k] * gi[k]
            hi[k] = yr[k] * gi[k] + yi[k] * gr[k]
        }
    }

    func impulse(shift tau: Double) {
        vDSP_vclr(&outR, 1, vDSP_Length(n))
        vDSP_vclr(&outI, 1, vDSP_Length(n))
        let step = 2 * Double.pi * tau / Double(n)
        for k in kLo...kHi {
            let ph = step * Double(k), c = Float(cos(ph)), s = Float(sin(ph))
            outR[k] = hr[k] * c - hi[k] * s
            outI[k] = hr[k] * s + hi[k] * c
        }
        transform(&outR, &outI, inverse: true)
        var scale = 1 / Float(n)
        let count = vDSP_Length(n)
        outR.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, count) }
        outI.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, count) }
    }
}
