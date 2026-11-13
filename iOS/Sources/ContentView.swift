// Sonar: the single screen. Map behind, live echo trace on top, three controls at the bottom.
import SwiftUI

struct ScopeView: View {
    let values: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let sorted = values.sorted()
            let lo = sorted[sorted.count / 2] + 3
            let hi = max(lo + 15, (values.dropFirst(values.count / 10).max() ?? lo) + 2)
            var line = Path()
            for (i, v) in values.enumerated() {
                let t = CGFloat(min(1, max(0, (v - lo) / (hi - lo))))
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: (size.height - 1) * (1 - t))
                if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.1)))
            context.stroke(line, with: .color(color), lineWidth: 1.25)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SonarModel
    private let accent = Color(red: 0.435, green: 1, blue: 0.784)

    var body: some View {
        ZStack {
            MapView(model: model).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sonar").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text(model.status).font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                ScopeView(values: model.scope, color: accent)
                    .frame(height: 54)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                HStack {
                    Text("0")
                    Spacer()
                    Text(model.detail).lineLimit(1)
                    Spacer()
                    Text("5 m")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, 20)
                .padding(.top, 5)
                Spacer()
                if !model.running && model.pings == 0 {
                    VStack(spacing: 10) {
                        Text("Paint the room with sound").font(.system(size: 22, weight: .medium))
                        Text("Press Start, point the bottom of the phone at things and move it slowly in every direction. Echoes that agree pile up on real walls.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 34)
                    Spacer()
                }
                controls
            }
        }
        .foregroundStyle(.white)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text("More").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Slider(value: $model.sharpness, in: 0.15...0.85).tint(.white)
                Text("Sharper").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            HStack {
                Button { model.clear() } label: {
                    Text("Clear").font(.system(size: 15)).frame(width: 84, height: 44).background(.white.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button { model.toggle() } label: {
                    Text(model.running ? "Stop" : "Start").font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                        .frame(width: 124, height: 48).background(.white, in: Capsule())
                }
                Spacer()
                Button { model.dark.toggle() } label: {
                    Image(systemName: model.dark ? "eye.slash" : "eye").font(.system(size: 17)).frame(width: 84, height: 44).background(.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}
