import Foundation

/// The percentage control and the renderer share the same logical-point
/// envelope. Bitmap resolution / Retina scale is deliberately not a size cap.
public struct CursorScaleLimits {
    public let range: ClosedRange<Double>
    public let conflicting: Bool
    public init(roles: [CursorRole], appearance: CursorAppearance, themeScale: Double, roleID: String? = nil) {
        var low = 0.25, high = 3.0
        for role in roles where !role.usesNative && !CursorCatalog.assetOnly(role.id) && (roleID == nil || role.id == roleID) {
            let fixed = roleID == nil ? role.scale : themeScale
            for clip in role.clips.values {
                let geometry = appearance.geometry(of: clip)
                low = max(low, 1 / (min(geometry.width, geometry.height) * fixed))
                high = min(high, 128 / (max(geometry.width, geometry.height) * fixed))
            }
        }
        conflicting = low > high + 1e-9
        // A pre-existing incompatible theme remains editable rather than
        // receiving a silently rewritten size when opening its controls.
        range = conflicting ? 0.25...3 : min(low, high)...high
    }
    public var percentages: ClosedRange<Double> { range.lowerBound * 100...range.upperBound * 100 }
    public func clamp(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
}
