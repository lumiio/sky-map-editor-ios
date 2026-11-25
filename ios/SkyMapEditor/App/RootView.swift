import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalSurface().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                Text("Sky 地图编辑器 · iOS").font(.headline)
                Text("原生 Swift + Metal 重写中").font(.caption).opacity(0.8)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
        }
    }
}
