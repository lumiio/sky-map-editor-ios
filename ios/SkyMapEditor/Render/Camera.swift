import simd

struct OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var yaw: Float = 0.7
    var pitch: Float = 0.45
    var distance: Float = 40
    var fovY: Float = 58 * .pi / 180

    func eye() -> SIMD3<Float> {
        let direction = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        return target + direction * distance
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        let near = max(0.05, distance * 0.01)
        let e = eye()
        let forward = normalize(target - e)
        let right = normalize(cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = cross(right, forward)
        let view = simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, -forward.x, 0),
            SIMD4<Float>(right.y, up.y, -forward.y, 0),
            SIMD4<Float>(right.z, up.z, -forward.z, 0),
            SIMD4<Float>(-dot(right, e), -dot(up, e), dot(forward, e), 1)
        ))
        let far = max(distance * 12 + 100, 200)
        let y = 1 / tan(fovY * 0.5)
        let x = y / max(aspect, 0.0001)
        let z = far / (near - far)
        let projection = simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
        return projection * view
    }

    mutating func frame(min boundsMin: SIMD3<Float>, max boundsMax: SIMD3<Float>) {
        let center = (boundsMin + boundsMax) * 0.5
        let extent = max(simd_length(boundsMax - boundsMin), 1)
        target = center
        distance = extent * 0.8
        yaw = 0.7
        pitch = 0.45
    }
}
