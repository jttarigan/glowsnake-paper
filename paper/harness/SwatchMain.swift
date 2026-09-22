import Foundation
import Metal
import CoreGraphics
import CoreText
import ImageIO
import simd

// Table-1 swatch generator (macOS, windowless). Renders each of the six
// shape kinds in isolation through the EXACT shipped pipeline (the same
// extracted runtime shader source and blending the measurement harnesses
// use), then writes small PNG chips for the paper's shape-kind table.
// Representative in-game parameters: a snake bead, a pellet, a ripple ring,
// a panel frame, a HUD digit, and the background gradient. The glyph swatch
// samples a real rasterized glyph (CoreText, same manual-RGBA8-context
// technique as the app's atlas baker).
//
// Usage: swatch_harness <outputDir>   -> <outputDir>/swatch_<kind>.png

@main
struct SwatchHarness {
    // Output px (square); overridable via argv[2]. `cell` = one grid cell.
    static var tile = 240
    static var cell: Float { Float(tile) / 3 }

    static func main() throws {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        if CommandLine.arguments.count > 2, let t = Int(CommandLine.arguments[2]) {
            tile = t
        }

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { fatalError("no Metal") }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "v_main")
        desc.fragmentFunction = library.makeFunction(name: "f_main")
        let att = desc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .sourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: sdesc)!

        let atlasTex = makeGlyphTexture(device: device)

        let rdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: tile, height: tile, mipmapped: false)
        rdesc.usage = [.renderTarget]
        rdesc.storageMode = .shared
        let target = device.makeTexture(descriptor: rdesc)!

        let c = Float(tile) / 2                       // tile center
        let mid = SIMD2<Float>(c, c)

        // One swatch per shape kind, with in-game-like parameters.
        var swatches: [(name: String, list: DrawList)] = []

        // rect — a snake-body bead (acid-mint family), slight rotation.
        var rect = DrawList()
        let mint = hsv2rgb(0.427, 0.85, 0.95)
        rect.add(.rect, center: mid, halfShape: SIMD2(cell * 0.48, cell * 0.48),
                 corner: cell * 0.2,
                 color: SIMD4(mint.x, mint.y, mint.z, 1),
                 glowColor: mint, glowStrength: 0.7, glowRadius: cell * 0.3,
                 rot: 0.35)
        swatches.append(("rect", rect))

        // circle — a pellet (cyan speed pill) mid-pulse.
        var circle = DrawList()
        let cyan = hsv2rgb(0.507, 0.95, 1.0)
        circle.add(.circle, center: mid, halfShape: SIMD2(cell * 0.45, cell * 0.45),
                   color: SIMD4(cyan.x, cyan.y, cyan.z, 1),
                   glowColor: cyan, glowStrength: 1.1, glowRadius: cell * 0.55)
        swatches.append(("circle", circle))

        // ring — an eat-shockwave ripple (hot-pink family), mid-flight.
        var ring = DrawList()
        let pink = hsv2rgb(0.920, 0.75, 1.0)
        ring.add(.ring, center: mid, halfShape: SIMD2(cell * 0.85, cell * 0.85),
                 color: SIMD4(pink.x, pink.y, pink.z, 0.9),
                 glowColor: pink, glowStrength: 0.5, glowRadius: cell * 0.4,
                 strokeThk: cell * 0.12)
        swatches.append(("ring", ring))

        // frame — a rounded panel border (neon-yellow family).
        var frame = DrawList()
        let yellow = hsv2rgb(0.161, 0.9, 1.0)
        frame.add(.frame, center: mid, halfShape: SIMD2(cell * 0.95, cell * 0.95),
                  corner: cell * 0.3,
                  color: SIMD4(yellow.x, yellow.y, yellow.z, 0.95),
                  glowColor: yellow, glowStrength: 0.6, glowRadius: cell * 0.25,
                  strokeThk: cell * 0.06)
        swatches.append(("frame", frame))

        // glyph — a HUD digit sampled from a real rasterized atlas.
        var glyph = DrawList()
        glyph.addGlyph(center: mid, size: SIMD2(cell * 1.7, cell * 2.1),
                       uvOrigin: SIMD2(0, 0), uvSize: SIMD2(1, 1),
                       color: rgba(1, 1, 1, 1))
        swatches.append(("glyph", glyph))

        // bg — the three-stop diagonal gradient (SceneBuilder's base stops).
        var bg = DrawList()
        bg.addBackground(viewSize: SIMD2(Float(tile), Float(tile)),
                         a: SIMD3(0.10, 0.02, 0.20),
                         b: SIMD3(0.20, 0.03, 0.30),
                         c: SIMD3(0.02, 0.10, 0.22))
        swatches.append(("bg", bg))

        for (name, list) in swatches {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            // The game's dark backdrop family, so chips sit on an in-game
            // ground rather than paper-white.
            rpd.colorAttachments[0].clearColor =
                MTLClearColor(red: 0.031, green: 0.012, blue: 0.059, alpha: 1)

            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
            var viewport = SIMD2<Float>(Float(tile), Float(tile))
            let buffer = device.makeBuffer(
                bytes: list.instances,
                length: MemoryLayout<GPUInstance>.stride * list.instances.count,
                options: .storageModeShared)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setFragmentTexture(atlasTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: list.instances.count)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            try writePNG(target, to: "\(outDir)/swatch_\(name).png")
            print("wrote swatch_\(name).png")
        }
    }

    /// A real glyph atlas holding one character, rasterized with CoreText into
    /// a manual RGBA8 context — the same technique the app's atlas baker uses.
    static func makeGlyphTexture(device: MTLDevice) -> MTLTexture {
        let size = 256
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: size, height: size,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 190, nil)
            let attrs: [NSAttributedString.Key: Any] =
                [NSAttributedString.Key(kCTFontAttributeName as String): font,
                 NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "8", attributes: attrs))
            let bounds = CTLineGetImageBounds(line, ctx)
            ctx.textPosition = CGPoint(
                x: (CGFloat(size) - bounds.width) / 2 - bounds.minX,
                y: (CGFloat(size) - bounds.height) / 2 - bounds.minY)
            CTLineDraw(line, ctx)
        }
        let tdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        let tex = device.makeTexture(descriptor: tdesc)!
        // Flip vertically on upload: CG is bottom-left origin, the shader's
        // uv (like the app's atlas) is top-left.
        pixels.withUnsafeBytes { raw in
            for row in 0..<size {
                tex.replace(region: MTLRegionMake2D(0, row, size, 1), mipmapLevel: 0,
                            withBytes: raw.baseAddress! + (size - 1 - row) * bytesPerRow,
                            bytesPerRow: bytesPerRow)
            }
        }
        return tex
    }

    static func writePNG(_ tex: MTLTexture, to path: String) throws {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        let ctx = CGContext(data: &bytes, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                        CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let img = ctx.makeImage()!
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString,
                                                         1, nil) else {
            fatalError("png destination failed: \(path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
