// Sonar: keeps a short history of phone poses from ARKit and answers where the speaker was at a given moment.
import Foundation
import simd
#if !targetEnvironment(macCatalyst)
import ARKit
#endif

struct Pose {
    var position: SIMD3<Float>
    var axis: SIMD3<Float>
    var transform: simd_float4x4
}

final class Tracker: NSObject {
    static let speakerOffset = SIMD4<Float>(0.136, -0.023, 0, 1)
    private var times: [TimeInterval] = []
    private var transforms: [simd_float4x4] = []
    private let lock = NSLock()
    private var normal = false

    var isTracking: Bool {
        lock.lock(); defer { lock.unlock() }
        return normal
    }

    func push(_ t: TimeInterval, _ m: simd_float4x4) {
        lock.lock(); defer { lock.unlock() }
        times.append(t)
        transforms.append(m)
        if times.count > 300 {
            times.removeFirst(100)
            transforms.removeFirst(100)
        }
    }

    func pose(at t: TimeInterval) -> Pose? {
        lock.lock(); defer { lock.unlock() }
        guard let newest = times.last, let oldest = times.first, t <= newest + 0.05, t >= oldest - 0.05 else { return nil }
        var i = times.count - 1
        while i > 0 && times[i - 1] >= t { i -= 1 }
        let b = transforms[i], tb = times[i]
        let a = i > 0 ? transforms[i - 1] : b, ta = i > 0 ? times[i - 1] : tb
        if tb - ta > 0.1 { return nil }
        let f = tb > ta ? Float(min(1, max(0, (t - ta) / (tb - ta)))) : 0
        let m = f < 0.5 ? a : b
        let p = simd_mix(a * Tracker.speakerOffset, b * Tracker.speakerOffset, SIMD4<Float>(repeating: f))
        let x = m.columns.0
        return Pose(position: SIMD3<Float>(p.x, p.y, p.z), axis: simd_normalize(SIMD3<Float>(x.x, x.y, x.z)), transform: m)
    }

    fileprivate func set(normal value: Bool) {
        lock.lock(); defer { lock.unlock() }
        normal = value
    }
}

#if !targetEnvironment(macCatalyst)
extension Tracker: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if case .normal = frame.camera.trackingState {
            set(normal: true)
            push(frame.timestamp, frame.camera.transform)
        } else {
            set(normal: false)
        }
    }
}
#endif
