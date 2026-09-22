import Foundation
import simd

/// Headless stand-in for the app's GlyphAtlas: identical API and identical
/// instance emission (one glyph quad per non-space character; spaces advance
/// the pen but emit nothing), with no CoreGraphics or Metal. Metrics
/// approximate the real 64 pt bold monospaced-digit system font — glyph
/// widths only affect quad sizes, never instance counts.
final class GlyphAtlas {
    let lineHeight: Float = 76
    /// Advance per character slot in atlas pixels (monospaced approximation).
    private let advance: Float = 42

    func width(_ string: String, pixelHeight: Float) -> Float {
        let scale = pixelHeight / lineHeight
        return Float(string.count) * advance * scale
    }

    func append(_ string: String, into list: inout DrawList,
                topLeft: SIMD2<Float>, pixelHeight: Float, color: SIMD4<Float>) {
        let scale = pixelHeight / lineHeight
        var penX = topLeft.x
        for ch in string {
            let w = advance * scale
            if ch != " " {
                list.addGlyph(center: SIMD2(penX + w * 0.5, topLeft.y + pixelHeight * 0.5),
                              size: SIMD2(w, pixelHeight),
                              uvOrigin: .zero, uvSize: .zero, color: color)
            }
            penX += w
        }
    }

    func appendCentered(_ string: String, into list: inout DrawList,
                        centerX: Float, top: Float, pixelHeight: Float,
                        color: SIMD4<Float>) {
        let w = width(string, pixelHeight: pixelHeight)
        append(string, into: &list, topLeft: SIMD2(centerX - w * 0.5, top),
               pixelHeight: pixelHeight, color: color)
    }
}
