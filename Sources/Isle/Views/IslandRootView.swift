import SwiftUI

struct IslandRootView: View {
    let env: AppEnvironment

    var body: some View {
        let layout = env.currentLayout()
        let shape = NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
        let elevated = layout.mode == .open || layout.mode == .banner

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: layout.width, height: layout.height)
                .shadow(color: .black.opacity(elevated ? 0.55 : 0), radius: elevated ? 20 : 0, y: elevated ? 8 : 0)

            IslandContentView(env: env, layout: layout)
                .padding(.horizontal, layout.topRadius)
                .frame(width: layout.width, height: layout.height, alignment: .top)
                .clipShape(shape)
                .overlay(alignment: .top) {
                    if env.vm.dropTargeted {
                        shape.stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(width: layout.width, height: layout.height)
                    }
                }
        }
        .opacity(layout.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(env.vm.isOpen ? Anim.open : Anim.close, value: layout)
        .environment(\.colorScheme, .dark)
    }
}

struct IslandContentView: View {
    let env: AppEnvironment
    let layout: IslandLayout

    var body: some View {
        let g = env.vm.geometry
        ZStack(alignment: .top) {
            switch layout.mode {
            case .closed:
                Color.clear
            case .compact(let kind):
                CompactView(env: env, kind: kind, side: layout.sideWidth, height: g.notchHeight)
                    .transition(.blurFade)
            case .sides:
                SidesActivityView(env: env, side: layout.sideWidth, height: g.notchHeight)
                    .transition(.blurFade)
            case .banner:
                BannerView(env: env, notchHeight: g.notchHeight)
                    .transition(.blurFade)
            case .open:
                OpenIslandView(env: env)
                    .transition(.blurFade)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
