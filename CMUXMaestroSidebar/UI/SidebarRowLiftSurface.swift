import SwiftUI

/// Decoration only: preserve the row's existing selected and activity surfaces beneath it.
struct SidebarRowLiftSurface: View {
    let lifted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SidebarRowLiftStyle.cornerRadius)
    }

    var body: some View {
        ZStack {
            shape.fill(Color(nsColor: .shadowColor))
                .shadow(color: Color(nsColor: .shadowColor).opacity(SidebarRowLiftStyle.nearShadowOpacity),
                        radius: SidebarRowLiftStyle.nearShadowRadius, y: SidebarRowLiftStyle.nearShadowY)
                .shadow(color: Color(nsColor: .shadowColor).opacity(SidebarRowLiftStyle.farShadowOpacity),
                        radius: SidebarRowLiftStyle.farShadowRadius, y: SidebarRowLiftStyle.farShadowY)
                .clipShape(ShadowExterior(), style: FillStyle(eoFill: true))
            shape.fill(Color(nsColor: .highlightColor).opacity(SidebarRowLiftStyle.highlightOpacity))
        }
        .opacity(lifted ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: SidebarRowLiftStyle.duration), value: lifted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct ShadowExterior: Shape {
        func path(in rect: CGRect) -> Path {
            let extent = 3 * (SidebarRowLiftStyle.nearShadowRadius + SidebarRowLiftStyle.farShadowRadius)
                + abs(SidebarRowLiftStyle.nearShadowY) + abs(SidebarRowLiftStyle.farShadowY)
            var path = Path()
            path.addRect(rect.insetBy(dx: -extent, dy: -extent))
            path.addPath(RoundedRectangle(cornerRadius: SidebarRowLiftStyle.cornerRadius).path(in: rect))
            return path
        }
    }
}
