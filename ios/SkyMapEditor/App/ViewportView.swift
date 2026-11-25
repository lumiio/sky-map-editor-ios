import MetalKit
import simd
import SwiftUI

struct ViewportView: UIViewRepresentable {
    let model: AppModel
    let scene: LevelScene

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var renderer: Renderer?
        var loadedScene = ""
        weak var view: MTKView?

        @objc func orbit(_ gesture: UIPanGestureRecognizer) {
            guard let renderer else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            renderer.camera.yaw -= Float(delta.x) * 0.006
            renderer.camera.pitch = min(max(renderer.camera.pitch - Float(delta.y) * 0.006, -1.45), 1.45)
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let renderer else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            let camera = renderer.camera
            let eye = camera.eye()
            let forward = simd_normalize(camera.target - eye)
            let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            let up = simd_cross(right, forward)
            let scale = camera.distance * 0.0016
            renderer.camera.target += (-right * Float(delta.x) + up * Float(delta.y)) * scale
        }

        @objc func zoom(_ gesture: UIPinchGestureRecognizer) {
            guard let renderer else { return }
            renderer.camera.distance = min(max(renderer.camera.distance / Float(gesture.scale), 0.5), 50000)
            gesture.scale = 1
        }
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.backgroundColor = .black
        guard let renderer = Renderer(view: view) else { return view }
        context.coordinator.renderer = renderer
        context.coordinator.view = view
        view.delegate = renderer

        let orbit = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.orbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:))))
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.materialTintVisible = model.materialTint
        guard context.coordinator.loadedScene != scene.name else { return }
        context.coordinator.loadedScene = scene.name
        context.coordinator.renderer?.setScene(scene)
    }
}
