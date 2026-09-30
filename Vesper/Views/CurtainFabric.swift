import SwiftUI

/// A moving cloth mesh: both geometry and fold lighting change over time.
/// Keeping this in Canvas supports iOS 17 without requiring a Metal-only device path.
struct CurtainFabric: View, Animatable {
    var progress: Double
    let time: Double
    let dark: Bool
    var animatableData: Double { get { progress } set { progress = newValue } }
    var body: some View {
        Canvas { context, size in draw(context: context, size: size) }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func draw(context: GraphicsContext, size: CGSize) {
        let columns = 22, rows = 24
        for side in 0..<2 {
            for row in 0..<rows {
                for column in 0..<columns {
                    drawPatch(context: context, size: size, side: side,
                              u: Double(column) / Double(columns), v: Double(row) / Double(rows))
                }
            }
        }
    }
    private func drawPatch(context: GraphicsContext, size: CGSize, side: Int, u: Double, v: Double) {
        let du: Double = 1.0 / 22.0, dv: Double = 1.0 / 24.0
        var patch = Path()
        patch.move(to: point(u, v, side: side, size: size))
        patch.addLine(to: point(u + du, v, side: side, size: size))
        patch.addLine(to: point(u + du, v + dv, side: side, size: size))
        patch.addLine(to: point(u, v + dv, side: side, size: size))
        patch.closeSubpath()
        let phase: Double = (u + du / 2) * Double.pi * 13 + sin(v * 4 + time * 0.6) * 0.45
        let fold: Double = cos(phase)
        let brightness: Double = dark ? 0.10 + (fold + 1) * 0.055 : 0.79 + (fold + 1) * 0.075
        let shade = Color(white: brightness).opacity(dark ? 0.98 : 0.96)
        context.fill(patch, with: .color(shade))
        context.stroke(patch, with: .color(shade), lineWidth: 0.5)
    }
    private func point(_ u: Double, _ v: Double, side: Int, size: CGSize) -> CGPoint {
        let fold: Double = sin(u * Double.pi * 13 + sin(v * 4 + time * 0.6) * 0.45)
        let wind: Double = sin(time * 0.7 + v * 3.7 + u * 2) * sin(v * Double.pi)
        let billow: Double = sin(v * Double.pi) * sin(progress * Double.pi)
        let horizontal: Double = (u * 0.515 - progress * 0.59) * Double(size.width)
        let displacement: Double = (fold * 5 + wind * 7 + billow * 55) * u
        let x: CGFloat = CGFloat(horizontal + displacement)
        let vertical: Double = v * Double(size.height)
        let ripple: Double = fold * sin(v * Double.pi) * (4 + progress * 10) + wind * 5
        return CGPoint(x: side == 0 ? x : size.width - x, y: CGFloat(vertical + ripple))
    }
}
