import SwiftUI

/// A moving cloth mesh: both geometry and fold lighting change over time.
/// Keeping this in Canvas supports iOS 17 without requiring a Metal-only device path.
struct CurtainFabric: View, Animatable {
    var progress: Double
    let time: Double
    let dark: Bool
    var animatableData: Double { get { progress } set { progress = newValue } }
    var body: some View {
        Canvas { context, size in
            let columns = 22, rows = 24
            for side in 0..<2 {
                for row in 0..<rows {
                    for column in 0..<columns {
                        let u = Double(column) / Double(columns), v = Double(row) / Double(rows)
                        let du = 1.0 / Double(columns), dv = 1.0 / Double(rows)
                        let points = [(u,v),(u+du,v),(u+du,v+dv),(u,v+dv)].map { point($0.0, $0.1, side: side, size: size) }
                        var patch = Path(); patch.move(to: points[0]); for point in points.dropFirst() { patch.addLine(to: point) }; patch.closeSubpath()
                        let fold = cos((u + du/2) * .pi * 13 + sin(v*4 + time*0.6)*0.45)
                        let brightness = dark ? 0.10 + (fold+1)*0.055 : 0.79 + (fold+1)*0.075
                        let shade = Color(white: brightness).opacity(dark ? 0.98 : 0.96)
                        context.fill(patch, with: .color(shade))
                        // A thin matching seam prevents subpixel gaps between mesh patches.
                        context.stroke(patch, with: .color(shade), lineWidth: 0.5)
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func point(_ u: Double, _ v: Double, side: Int, size: CGSize) -> CGPoint {
        let fold = sin(u * .pi * 13 + sin(v*4 + time*0.6)*0.45)
        let wind = sin(time*0.7 + v*3.7 + u*2) * sin(v * .pi)
        let billow = sin(v * .pi) * sin(progress * .pi)
        let x = (u * 0.515 - progress * 0.59) * size.width + (fold * 5 + wind * 7 + billow * 55) * u
        let y = v * size.height + fold * sin(v * .pi) * (4 + progress*10) + wind*5
        return CGPoint(x: side == 0 ? x : size.width-x, y: y)
    }
}
