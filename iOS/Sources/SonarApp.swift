// Sonar for iPhone: app entry, plus an off-screen Mac Catalyst mode for checking the build without a phone.
import SwiftUI

@main
struct SonarApp: App {
    @StateObject private var model = SonarModel()

    init() {
        Demo.prepare()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear { Demo.run(model) }
        }
    }
}

enum Demo {
    private static var args: [String] { ProcessInfo.processInfo.arguments }
    private static var wanted: Bool { args.contains("--demo") || args.contains("--listen") || args.contains("--replay") }

    private static func checkDsp() {
        let proc = EchoProcessor(fs: 48000)
        let n = proc.pc.n, wave = proc.pc.wave
        var seed: UInt64 = 7
        var frame = [Float](repeating: 0, count: n)
        for step in 0..<60 {
            let echoLag = 560 + step / 2
            for i in 0..<n {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.002
                frame[i] = 0.3 * wave[(i - 1234 + n) % n] + 0.0015 * wave[(i - 1234 - echoLag + 2 * n) % n] + noise
            }
            guard let echo = frame.withUnsafeBufferPointer({ proc.process($0.baseAddress!) }), step % 10 == 9 else { continue }
            var best = 0
            for k in 0..<echo.profile.count where echo.profile[k] > echo.profile[best] { best = k }
            print(String(format: "dsp step %d lag %.3f snr %.1f ready %d echo at %.3f m (true %.3f m) value %.5f", step, echo.lag, echo.snr,
                         echo.ready ? 1 : 0, EchoProcessor.rMin + (Double(best) + 0.5) * EchoProcessor.step, Double(echoLag) * proc.binSize, echo.profile[best]))
        }
    }

    static func prepare() {
        if args.contains("--first-chirp") {
            SonarConfig.chirp = 1024
            SonarConfig.f1 = 3000
            SonarConfig.f2 = 18000
        }
        if let i = args.firstIndex(of: "--needed"), i + 1 < args.count, let v = Float(args[i + 1]) { PlaneFinder.needed = v }
        if let i = args.firstIndex(of: "--contrast"), i + 1 < args.count, let v = Float(args[i + 1]) { PlaneFinder.minContrast = v }
        if args.contains("--dsp") {
            checkDsp()
            exit(0)
        }
        #if targetEnvironment(macCatalyst)
        guard args.contains("--demo") || args.contains("--replay"), let cls = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = cls.value(forKey: "sharedApplication") as? NSObject else { return }
        let selector = NSSelectorFromString("setActivationPolicy:")
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Bool
        _ = unsafeBitCast(app.method(for: selector), to: Setter.self)(app, selector, 1)
        #endif
    }

    static func run(_ model: SonarModel) {
        guard wanted else { return }
        #if targetEnvironment(macCatalyst)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let size = CGSize(width: 414, height: 896)
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: args.contains("--listen") ? 80 : -3000, y: 100), size: size)))
        }
        #endif
        if args.contains("--demo") { model.simulate() }
        if let i = args.firstIndex(of: "--replay"), i + 1 < args.count { model.replay(args[i + 1]) }
        if args.contains("--listen") {
            model.verbose = true
            model.start()
        }
        let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 4
        let shot = args.firstIndex(of: "--shot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if let shot, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
               let window = scene.keyWindow ?? scene.windows.first {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: shot))
            }
            exit(0)
        }
    }
}
