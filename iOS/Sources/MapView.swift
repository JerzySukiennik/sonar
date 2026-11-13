// Sonar: SceneKit view of the echo map. On the phone it is an AR view, so the map stays glued to the real room.
import SceneKit
import SwiftUI
#if !targetEnvironment(macCatalyst)
import ARKit
#endif

final class MapRenderer {
    let scene = SCNScene()
    private let cloud = SCNNode()
    private let trail = SCNNode()
    private let dimmer = SCNNode()
    private weak var view: SCNView?
    private var dimAmount: CGFloat = 1

    init() {
        cloud.renderingOrder = 10
        trail.renderingOrder = 11
        scene.rootNode.addChildNode(cloud)
        scene.rootNode.addChildNode(trail)
        let plane = SCNPlane(width: 600, height: 600)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.black
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.isDoubleSided = true
        plane.materials = [material]
        dimmer.geometry = plane
        dimmer.position = SCNVector3(0, 0, -40)
        dimmer.renderingOrder = -10
    }

    func attach(_ v: SCNView) {
        view = v
        v.scene = scene
        v.backgroundColor = .black
        v.antialiasingMode = .none
        #if targetEnvironment(macCatalyst)
        let eye = SCNNode()
        let camera = SCNCamera()
        camera.zFar = 200
        camera.zNear = 0.05
        camera.fieldOfView = 58
        eye.camera = camera
        eye.position = SCNVector3(4.6, 3.4, 7.2)
        eye.look(at: SCNVector3(0.2, -0.1, 0.6))
        scene.rootNode.addChildNode(eye)
        v.pointOfView = eye
        v.allowsCameraControl = true
        #endif
        dim(dimAmount)
    }

    func dim(_ amount: CGFloat) {
        dimAmount = amount
        if dimmer.parent == nil, let eye = view?.pointOfView { eye.addChildNode(dimmer) }
        dimmer.opacity = amount
    }

    func show(points: [SIMD3<Float>], values: [Float]) {
        guard !points.isEmpty else { cloud.geometry = nil; return }
        let colors = values.map { v -> SIMD4<Float> in
            let t = 0.14 + 0.46 * v, glow = max(0, v - 0.8) * 1.2
            return SIMD4<Float>(min(1, 0.435 * t + glow), min(1, t + glow * 0.3), min(1, 0.784 * t + glow * 0.6), 1)
        }
        cloud.geometry = geometry(points, colors, size: 0.045, maxRadius: 6)
    }

    func show(path: [SIMD3<Float>]) {
        guard !path.isEmpty else { trail.geometry = nil; return }
        let colors = [SIMD4<Float>](repeating: SIMD4<Float>(0.4, 0.4, 0.4, 1), count: path.count)
        trail.geometry = geometry(path, colors, size: 0.012, maxRadius: 2.5)
    }

    private func geometry(_ points: [SIMD3<Float>], _ colors: [SIMD4<Float>], size: CGFloat, maxRadius: CGFloat) -> SCNGeometry {
        let vertexData = points.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let indices = [UInt32](0..<UInt32(points.count))
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertices = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: points.count, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let tints = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                      componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let element = SCNGeometryElement(data: indexData, primitiveType: .point, primitiveCount: points.count, bytesPerIndex: 4)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = maxRadius
        let result = SCNGeometry(sources: [vertices, tints], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        result.materials = [material]
        return result
    }
}

struct MapView: UIViewRepresentable {
    let model: SonarModel

    func makeUIView(context: Context) -> SCNView {
        #if targetEnvironment(macCatalyst)
        let view = SCNView()
        #else
        let view = ARSCNView()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.session.delegate = model.tracker
        model.startTracking = { [weak view] in
            guard let view, ARWorldTrackingConfiguration.isSupported else { return }
            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = .gravity
            view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
        #endif
        model.renderer.attach(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
