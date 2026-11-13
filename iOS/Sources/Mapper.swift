// Sonar: backprojects range profiles from many phone positions into a voxel grid. Echoes that agree pile up on real surfaces.
import Accelerate
import Foundation
import simd

final class Mapper {
    static let voxel: Float = 0.05
    let nx = 128
    let ny = 64
    let nz = 128
    private var acc: [Float]
    private var weight: [Float]
    private var score: [Float]
    private var smooth: [Float] = []
    private(set) var origin = SIMD3<Float>(repeating: 0)
    private(set) var count = 0
    private(set) var started = false
    private var last = SIMD3<Float>(repeating: .infinity)

    init() {
        let total = nx * ny * nz
        acc = [Float](repeating: 0, count: total)
        weight = [Float](repeating: 0, count: total)
        score = [Float](repeating: 0, count: total)
    }

    func reset(around center: SIMD3<Float>) {
        origin = center - SIMD3<Float>(Float(nx) * Mapper.voxel / 2, 1.9, Float(nz) * Mapper.voxel / 2)
        vDSP_vclr(&acc, 1, vDSP_Length(acc.count))
        vDSP_vclr(&weight, 1, vDSP_Length(weight.count))
        count = 0
        started = true
        last = SIMD3<Float>(repeating: .infinity)
    }

    func add(position p: SIMD3<Float>, axis: SIMD3<Float>, profile: [Float], binSize: Float, rMin: Float, rMax: Float) -> Bool {
        if simd_distance(p, last) < 0.015 { return false }
        let m = profile.count
        let w = max(1, Int((Mapper.voxel / binSize).rounded()))
        if smooth.count != m + 1 { smooth = [Float](repeating: 0, count: m + 1) }
        var run: Float = 0, top: Float = 0
        for i in 0..<m {
            run += profile[i]
            if i >= w { run -= profile[i - w] }
            let c = i - w / 2
            if c >= 0 {
                let v = max(0, run / Float(w))
                smooth[c] = v
                if v > top { top = v }
            }
        }
        for c in max(0, m - w / 2)...m { smooth[c] = 0 }
        if top <= 0 { return false }
        last = p
        let v = Mapper.voxel, inv = 1 / binSize, rMin2 = rMin * rMin, rMax2 = rMax * rMax, limit = Float(m - 1)
        let x0 = origin.x + v / 2 - p.x, y0 = origin.y + v / 2 - p.y, z0 = origin.z + v / 2 - p.z
        let ax = axis.x, ay = axis.y, az = axis.z
        let nx = self.nx, ny = self.ny, nz = self.nz
        acc.withUnsafeMutableBufferPointer { a in
            weight.withUnsafeMutableBufferPointer { ws in
                smooth.withUnsafeBufferPointer { s in
                    for iz in 0..<nz {
                        let dz = z0 + Float(iz) * v, dz2 = dz * dz
                        if dz2 >= rMax2 { continue }
                        for iy in 0..<ny {
                            let dy = y0 + Float(iy) * v, dyz2 = dy * dy + dz2
                            if dyz2 >= rMax2 { continue }
                            let ayz = dy * ay + dz * az
                            var c = (iz * ny + iy) * nx
                            for ix in 0..<nx {
                                let dx = x0 + Float(ix) * v, r2 = dx * dx + dyz2
                                if r2 >= rMin2 && r2 < rMax2 {
                                    let r = r2.squareRoot(), f = min(r * inv, limit), i = Int(f)
                                    let e = s[i] + (f - Float(i)) * (s[i + 1] - s[i])
                                    let b = 0.5 + 0.5 * (dx * ax + ayz) / r
                                    let g = 0.25 + 0.75 * b * b
                                    a[c] += e * g
                                    ws[c] += g
                                }
                                c += 1
                            }
                        }
                    }
                }
            }
        }
        count += 1
        return true
    }

    func points(threshold: Float, limit: Int = 30000) -> (positions: [SIMD3<Float>], values: [Float]) {
        let total = nx * ny * nz
        var top: Float = 0
        acc.withUnsafeBufferPointer { a in
            weight.withUnsafeBufferPointer { ws in
                score.withUnsafeMutableBufferPointer { sc in
                    for i in 0..<total {
                        let s = a[i] / (ws[i] + 20)
                        sc[i] = s
                        if s > top { top = s }
                    }
                }
            }
        }
        guard top > 0 else { return ([], []) }
        var cut = threshold * top
        var hist = [Int](repeating: 0, count: 64)
        var n = 0
        let span = top - cut
        score.withUnsafeBufferPointer { sc in
            for i in 0..<total where sc[i] > cut {
                n += 1
                hist[min(63, Int((sc[i] - cut) / span * 64))] += 1
            }
        }
        if n > limit {
            var keep = 0, bin = 63
            while bin > 0 && keep + hist[bin] <= limit { keep += hist[bin]; bin -= 1 }
            cut += span * Float(bin + 1) / 64
        }
        var positions: [SIMD3<Float>] = [], values: [Float] = []
        positions.reserveCapacity(min(n, limit))
        values.reserveCapacity(min(n, limit))
        let v = Mapper.voxel, range = max(top - cut, 1e-12)
        score.withUnsafeBufferPointer { sc in
            for i in 0..<total where sc[i] > cut {
                let ix = i % nx, iy = (i / nx) % ny, iz = i / (nx * ny)
                positions.append(origin + SIMD3<Float>(Float(ix) + 0.5, Float(iy) + 0.5, Float(iz) + 0.5) * v)
                values.append((sc[i] - cut) / range)
            }
        }
        return (positions, values)
    }
}
