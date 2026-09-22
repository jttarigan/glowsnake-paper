import Foundation
import Metal
import CoreGraphics
import ImageIO
import simd

// Overdraw-heatmap generator (macOS, windowless). Autopilots a seeded game
// to the x8 finale, captures the peak-load frame, and renders it twice:
// once through the shipped pipeline (the figure's left panel), and once
// with an additive counting shader whose per-pixel sum is the number of
// rasterized quads covering that pixel — the overdraw the fill-rate
// analysis talks about. The count field is colormapped (viridis) to PNG.
//
// Usage: heatmap_harness <outputDir>
//   -> overdraw_frame.png, overdraw_heat.png (+ stats on stdout)

let coverageShader = """
#include <metal_stdlib>
using namespace metal;
struct Instance {
    float4 a; float4 b; float4 color; float4 glow; float4 uv; float4 misc;
};
struct VOut { float4 pos [[position]]; };
vertex VOut cov_v(uint vid [[vertex_id]], uint iid [[instance_id]],
                  constant Instance* insts [[buffer(0)]],
                  constant float2& viewport [[buffer(1)]]) {
    float2 corners[4] = { float2(-0.5,-0.5), float2(0.5,-0.5),
                          float2(-0.5, 0.5), float2(0.5, 0.5) };
    Instance ins = insts[iid];
    float2 px = ins.a.xy + corners[vid] * (ins.a.zw * 2.0);
    float2 ndc = (px / viewport) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    VOut o; o.pos = float4(ndc, 0, 1); return o;
}
fragment float4 cov_f(VOut in [[stage_in]]) {
    return float4(1.0/64.0, 0, 0, 0);   // additive: 64ths per layer
}
"""

@main
struct HeatmapHarness {
    static let viewW: Float = 1170, viewH: Float = 2532
    static let topInset: Float = (47 + 34) * 3

    static func makeLayout() -> Layout {
        let availH = viewH * 0.72 - topInset
        let cell = min(viewW / Float(GameModel.cols + 2), availH / Float(GameModel.rows))
        let boardW = cell * Float(GameModel.cols)
        let boardH = cell * Float(GameModel.rows)
        return Layout(viewSize: SIMD2(viewW, viewH), cell: cell, textUnit: viewW * 0.05,
                      boardX: (viewW - boardW) * 0.5,
                      boardY: topInset + (availH - boardH) * 0.5,
                      boardW: boardW, boardH: boardH)
    }

    static func steer(_ g: GameModel) {
        guard !g.isDying, !g.isGameOver, let head = g.snake.last else { return }
        let target = g.foods.min {
            abs($0.point.x - head.x) + abs($0.point.y - head.y) <
            abs($1.point.x - head.x) + abs($1.point.y - head.y)
        }
        if let t = target { g.handle(.setDestination(t.point)) }
    }

    /// Seeded autopilot to the x8 finale; returns the peak-instance frame.
    static func capturePeakFinaleFrame(layout: Layout, scene: SceneBuilder) -> DrawList {
        GameModel.fxScale = 8
        Rand.seed(12345)
        let g = GameModel()
        var t = 0.0
        let dt = 1.0 / 60.0
        var best = DrawList()
        while t < 240 && !g.isGameOver {
            steer(g)
            g.tick(dt)
            if g.isDying {
                let list = scene.build(game: g, layout: layout, hueShift: 0.3,
                    foodPulse: 0.5, headPulse: 0.5, dashTint: 0, pathPhase: 0,
                    fluidPhase: 0.5, scoreScale: 1, emberTime: t)
                if list.instances.count > best.instances.count { best = list }
            }
            t += dt
        }
        return best
    }

    static func main() throws {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { fatalError("no Metal") }

        let layout = makeLayout()
        let scene = SceneBuilder(atlas: GlyphAtlas())
        let list = capturePeakFinaleFrame(layout: layout, scene: scene)
        print("captured frame: \(list.instances.count) instances")

        // Analytic overdraw factor (matches the paper's definition).
        var area = 0.0
        for inst in list.instances { area += Double(inst.a.z * 2 * inst.a.w * 2) }
        let odFactor = area / Double(viewW * viewH)

        let W = Int(viewW), H = Int(viewH)
        func target(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: W, height: H, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .shared
            return device.makeTexture(descriptor: d)!
        }
        var viewport = SIMD2<Float>(viewW, viewH)
        let buffer = device.makeBuffer(
            bytes: list.instances,
            length: MemoryLayout<GPUInstance>.stride * list.instances.count,
            options: .storageModeShared)

        // ---- Pass 1: the shipped pipeline (left panel) ----------------------
        let appLib = try device.makeLibrary(source: shaderSource, options: nil)
        let appDesc = MTLRenderPipelineDescriptor()
        appDesc.vertexFunction = appLib.makeFunction(name: "v_main")
        appDesc.fragmentFunction = appLib.makeFunction(name: "f_main")
        let a0 = appDesc.colorAttachments[0]!
        a0.pixelFormat = .bgra8Unorm
        a0.isBlendingEnabled = true
        a0.rgbBlendOperation = .add
        a0.alphaBlendOperation = .add
        a0.sourceRGBBlendFactor = .sourceAlpha
        a0.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a0.sourceAlphaBlendFactor = .sourceAlpha
        a0.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let appPipe = try device.makeRenderPipelineState(descriptor: appDesc)

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear; sdesc.magFilter = .linear
        let sampler = device.makeSamplerState(descriptor: sdesc)!
        // Transparent 1x1 atlas: HUD glyph quads contribute nothing visible
        // (the caption notes the omission); coverage still counts them.
        let tdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let atlasTex = device.makeTexture(descriptor: tdesc)!
        var clear: [UInt8] = [0, 0, 0, 0]
        atlasTex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                         withBytes: &clear, bytesPerRow: 4)

        let colorTarget = target(.bgra8Unorm)
        do {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTarget
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
            enc.setRenderPipelineState(appPipe)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: 8, index: 1)
            enc.setFragmentTexture(atlasTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: list.instances.count)
            enc.endEncoding()
            cmd.commit(); cmd.waitUntilCompleted()
        }
        try writeBGRA(colorTarget, to: "\(outDir)/overdraw_frame.png")

        // ---- Pass 2: additive coverage counting -----------------------------
        let covLib = try device.makeLibrary(source: coverageShader, options: nil)
        let covDesc = MTLRenderPipelineDescriptor()
        covDesc.vertexFunction = covLib.makeFunction(name: "cov_v")
        covDesc.fragmentFunction = covLib.makeFunction(name: "cov_f")
        let c0 = covDesc.colorAttachments[0]!
        c0.pixelFormat = .rgba16Float
        c0.isBlendingEnabled = true
        c0.rgbBlendOperation = .add
        c0.sourceRGBBlendFactor = .one
        c0.destinationRGBBlendFactor = .one
        c0.alphaBlendOperation = .add
        c0.sourceAlphaBlendFactor = .one
        c0.destinationAlphaBlendFactor = .one
        let covPipe = try device.makeRenderPipelineState(descriptor: covDesc)

        let covTarget = target(.rgba16Float)
        do {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = covTarget
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
            enc.setRenderPipelineState(covPipe)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: 8, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: list.instances.count)
            enc.endEncoding()
            cmd.commit(); cmd.waitUntilCompleted()
        }

        // Read counts (r * 64), colormap with viridis, write PNG.
        var half = [UInt16](repeating: 0, count: W * H * 4)
        covTarget.getBytes(&half, bytesPerRow: W * 8,
                           from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        func h2f(_ h: UInt16) -> Float {
            var out: Float = 0
            withUnsafeMutablePointer(to: &out) { fp in
                var src = h
                withUnsafeMutablePointer(to: &src) { sp in
                    var f16 = Float16(bitPattern: sp.pointee)
                    fp.pointee = Float(f16)
                }
            }
            return out
        }
        var counts = [Float](repeating: 0, count: W * H)
        var maxC: Float = 0, sum: Double = 0
        for i in 0..<(W * H) {
            let c = h2f(half[i * 4]) * 64
            counts[i] = c
            maxC = max(maxC, c)
            sum += Double(c)
        }
        let sorted = counts.sorted()
        let med = sorted[W * H / 2], p99 = sorted[Int(Double(W * H) * 0.99)]
        print(String(format: "overdraw: mean %.1f  median %.0f  p99 %.0f  max %.0f  (analytic factor %.1f)",
                     sum / Double(W * H), med, p99, maxC, odFactor))

        // Viridis (8 anchors, matplotlib-faithful enough for a figure).
        let vir: [SIMD3<Float>] = [
            SIMD3(0.267, 0.005, 0.329), SIMD3(0.283, 0.141, 0.458),
            SIMD3(0.254, 0.265, 0.530), SIMD3(0.207, 0.372, 0.553),
            SIMD3(0.164, 0.471, 0.558), SIMD3(0.128, 0.567, 0.551),
            SIMD3(0.135, 0.659, 0.518), SIMD3(0.993, 0.906, 0.144)]
        func viridis(_ t: Float) -> SIMD3<Float> {
            let x = max(0, min(1, t)) * Float(vir.count - 1)
            let i = min(Int(x), vir.count - 2)
            return simd_mix(vir[i], vir[i + 1], SIMD3(repeating: x - Float(i)))
        }
        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        for i in 0..<(W * H) {
            let c = viridis(log(1 + counts[i]) / log(1 + maxC))
            rgba[i * 4 + 0] = UInt8(c.x * 255)
            rgba[i * 4 + 1] = UInt8(c.y * 255)
            rgba[i * 4 + 2] = UInt8(c.z * 255)
            rgba[i * 4 + 3] = 255
        }
        try writeRGBA(rgba, W, H, to: "\(outDir)/overdraw_heat.png")
        print("wrote overdraw_frame.png, overdraw_heat.png")
    }

    static func writeBGRA(_ tex: MTLTexture, to path: String) throws {
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
        try save(ctx.makeImage()!, path)
    }

    static func writeRGBA(_ bytes: [UInt8], _ w: Int, _ h: Int, to path: String) throws {
        var b = bytes
        let ctx = CGContext(data: &b, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try save(ctx.makeImage()!, path)
    }

    static func save(_ img: CGImage, _ path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
