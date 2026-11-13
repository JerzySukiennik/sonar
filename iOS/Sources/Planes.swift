// Sonar: finds flat surfaces. A wall at distance d along normal n is heard at range d - n.p from phone position p,
// so every ping votes for all (n, d) that explain its echoes. Real walls collect votes from every position; clutter smears out.
import Foundation
import simd

final class PlaneFinder {
    struct Plane {
        var normal: SIMD3<Float>
        var rho: Float
        var strength: Float
        var contrast: Float
    }

    static let directions = 800
    static let step: Float = 0.025
    static let rhoMin: Float = -3
    static let bins = 400
    static let needed: Float = 0.07
    private let normals: [SIMD3<Float>]
    private var votes: [Float]
    private var mean: [Float]
    private(set) var center = SIMD3<Float>(repeating: 0)
    private(set) var pings = 0
    private(set) var planes: [Plane] = []
    private(set) var coverage: Float = 0
    private(set) var trail: [SIMD3<Float>] = []
    private var last = SIMD3<Float>(repeating: .infinity)
    private var sum = SIMD3<Float>(repeating: 0)
    private var squares = SIMD3<Float>(repeating: 0)
    private var crosses = SIMD3<Float>(repeating: 0)
    private var clutter: [Float] = []
    private var moving: [Float] = []

    init() {
        var list: [SIMD3<Float>] = []
        let golden = Float.pi * (1 + Float(5).squareRoot())
        for i in 0..<PlaneFinder.directions {
            let t = (Float(i) + 0.5) / Float(PlaneFinder.directions)
            let phi = acos(1 - 2 * t), theta = golden * (Float(i) + 0.5)
            list.append(SIMD3<Float>(cos(theta) * sin(phi), cos(phi), sin(theta) * sin(phi)))
        }
        normals = list
        votes = [Float](repeating: 0, count: PlaneFinder.directions * PlaneFinder.bins)
        mean = [Float](repeating: 0, count: PlaneFinder.bins)
    }

    func reset(around point: SIMD3<Float>) {
        center = point
        for i in votes.indices { votes[i] = 0 }
        pings = 0
        planes = []
        coverage = 0
        trail = []
        last = SIMD3<Float>(repeating: .infinity)
        sum = SIMD3<Float>(repeating: 0)
        squares = SIMD3<Float>(repeating: 0)
        crosses = SIMD3<Float>(repeating: 0)
        clutter = []
    }

    func add(position p: SIMD3<Float>, profile: [Float], rMin: Float) -> Bool {
        if simd_distance(p, last) < 0.015 { return false }
        guard profile.contains(where: { $0 > 0 }) else { return false }
        last = p
        let d = p - center
        let bins = PlaneFinder.bins, step = PlaneFinder.step, rhoMin = PlaneFinder.rhoMin, count = profile.count
        if clutter.count != count {
            clutter = [Float](repeating: 0, count: count)
            moving = clutter
        }
        let alpha = max(0.05, 1 / Float(pings + 1))
        for i in 0..<count {
            clutter[i] += alpha * (profile[i] - clutter[i])
            moving[i] = max(0, profile[i] - 1.2 * clutter[i])
        }
        votes.withUnsafeMutableBufferPointer { v in
            moving.withUnsafeBufferPointer { a in
                for j in 0..<PlaneFinder.directions {
                    let f = (rMin + simd_dot(normals[j], d) - rhoMin) / step
                    let b = Int(f.rounded(.down)), frac = f - Float(b)
                    if b < 0 || b + count + 1 >= bins { continue }
                    var o = j * bins + b
                    for i in 0..<count {
                        let x = a[i]
                        if x > 0 {
                            v[o] += x * (1 - frac)
                            v[o + 1] += x * frac
                        }
                        o += 1
                    }
                }
            }
        }
        sum += d
        squares += d * d
        crosses += SIMD3<Float>(d.x * d.y, d.x * d.z, d.y * d.z)
        trail.append(p)
        pings += 1
        return true
    }

    private func smallestSpread() -> Float {
        guard pings > 3 else { return 0 }
        let n = Float(pings), m = sum / n
        let a00 = squares.x / n - m.x * m.x, a11 = squares.y / n - m.y * m.y, a22 = squares.z / n - m.z * m.z
        let a01 = crosses.x / n - m.x * m.y, a02 = crosses.y / n - m.x * m.z, a12 = crosses.z / n - m.y * m.z
        let p1 = a01 * a01 + a02 * a02 + a12 * a12
        let q = (a00 + a11 + a22) / 3
        let p2 = (a00 - q) * (a00 - q) + (a11 - q) * (a11 - q) + (a22 - q) * (a22 - q) + 2 * p1
        let p = (p2 / 6).squareRoot()
        if p < 1e-9 { return max(0, q).squareRoot() }
        let b00 = (a00 - q) / p, b11 = (a11 - q) / p, b22 = (a22 - q) / p, b01 = a01 / p, b02 = a02 / p, b12 = a12 / p
        let det = b00 * (b11 * b22 - b12 * b12) - b01 * (b01 * b22 - b12 * b02) + b02 * (b01 * b12 - b11 * b02)
        let phi = acos(max(-1, min(1, det / 2))) / 3
        return max(0, q + 2 * p * cos(phi + 2 * Float.pi / 3)).squareRoot()
    }

    func detect() {
        coverage = min(1, smallestSpread() / PlaneFinder.needed)
        guard pings >= 30, coverage >= 1 else { planes = []; return }
        let bins = PlaneFinder.bins, count = PlaneFinder.directions
        var top: Float = 0
        for b in 0..<bins { mean[b] = 0 }
        votes.withUnsafeBufferPointer { v in
            for j in 0..<count {
                let o = j * bins
                for b in 0..<bins {
                    let x = v[o + b]
                    mean[b] += x
                    if x > top { top = x }
                }
            }
        }
        guard top > 0 else { planes = []; return }
        for b in 0..<bins { mean[b] /= Float(count) }
        var candidates: [(value: Float, direction: Int, bin: Int, contrast: Float)] = []
        votes.withUnsafeBufferPointer { v in
            for j in 0..<count {
                let o = j * bins
                for b in 2..<(bins - 2) {
                    let x = v[o + b]
                    if x < 0.3 * top || x < v[o + b - 1] || x < v[o + b + 1] { continue }
                    let base = max(mean[b - 2], mean[b - 1], mean[b], mean[b + 1], mean[b + 2])
                    let contrast = x / (base + 1e-9)
                    if contrast >= 3 { candidates.append((x, j, b, contrast)) }
                }
            }
        }
        candidates.sort { $0.value > $1.value }
        var found: [Plane] = []
        for c in candidates {
            let normal = normals[c.direction], rho = PlaneFinder.rhoMin + Float(c.bin) * PlaneFinder.step
            if found.contains(where: { simd_dot($0.normal, normal) > 0.7 && abs($0.rho - rho) < 0.4 }) { continue }
            found.append(Plane(normal: normal, rho: rho, strength: c.value / top, contrast: c.contrast))
            if found.count == 6 { break }
        }
        planes = found
    }

    func range(of plane: Plane, from p: SIMD3<Float>) -> Float {
        plane.rho - simd_dot(plane.normal, p - center)
    }

    func points() -> (positions: [SIMD3<Float>], values: [Float]) {
        guard !planes.isEmpty, pings > 0 else { return ([], []) }
        var positions: [SIMD3<Float>] = [], values: [Float] = []
        let centroid = center + sum / Float(pings)
        for plane in planes {
            let n = plane.normal
            let helper = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let u = simd_normalize(simd_cross(n, helper)), v = simd_cross(n, u)
            let middle = centroid + n * range(of: plane, from: centroid)
            for a in -13...13 {
                for b in -13...13 {
                    let x = Float(a) * 0.06, y = Float(b) * 0.06
                    if x * x + y * y > 0.64 { continue }
                    positions.append(middle + u * x + v * y)
                    values.append(0.1 + 0.25 * plane.strength)
                }
            }
            for i in stride(from: 0, to: trail.count, by: 2) {
                positions.append(trail[i] + n * range(of: plane, from: trail[i]))
                values.append(1)
            }
        }
        return (positions, values)
    }
}
