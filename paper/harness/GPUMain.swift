import Foundation
import Dispatch
import Metal
import simd

// Offscreen GPU measurement harness (macOS, windowless). Replicates the app's
// Renderer byte-for-byte — same runtime-compiled shader source, same alpha
// blending, same .bgra8Unorm target at iPhone 12 resolution (1170x2532) —
// but renders into a private texture that is never presented. Three tests:
//
//   1. Shader/pipeline compile time (the app's launch cost).
//   2. Stress sweep: a real late-game frame + k synthetic shards,
//      GPU time per frame as k grows -> paper's headroom curve (Mac GPU).
//   3. 1 instanced draw call vs N individual draw calls for the same scene
//      -> CPU encode cost ratio (the "why batching matters" chart).
//
// Usage: gpu_harness <outputDir>

@main
struct GPUHarness {

    // ---- iPhone 12 geometry, as in the census harness -----------------------
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

    // ---- Scene generation (reuses the pure layers) --------------------------

    static func steer(_ g: GameModel) {
        guard !g.isDying, !g.isGameOver, !g.won, let head = g.snake.last else { return }
        let target = g.foods.min {
            abs($0.point.x - head.x) + abs($0.point.y - head.y) <
            abs($1.point.x - head.x) + abs($1.point.y - head.y)
        }
        if let t = target { g.handle(.setDestination(t.point)) }
    }

    static func buildFrame(_ g: GameModel, layout: Layout, scene: SceneBuilder,
                           t: Double) -> DrawList {
        scene.build(game: g, layout: layout, hueShift: 0.3,
                    foodPulse: Float(0.5 + 0.5 * sin(t * 5)),
                    headPulse: Float(0.5 + 0.5 * sin(t * 6)),
                    dashTint: 0, pathPhase: Float(t.truncatingRemainder(dividingBy: 1)),
                    fluidPhase: (t * 0.1).truncatingRemainder(dividingBy: 1),
                    scoreScale: 1, emberTime: t)
    }

    /// Autopilot until `until` says stop; returns the draw list at that frame.
    static func captureFrame(layout: Layout, scene: SceneBuilder,
                             until: (GameModel, Double) -> Bool) -> DrawList {
        let dt = 1.0 / 60.0
        while true {   // retry games until the condition is met
            let g = GameModel()
            var t = 0.0
            while t < 240 && !g.isGameOver {
                steer(g)
                g.tick(dt)
                if until(g, t) { return buildFrame(g, layout: layout, scene: scene, t: t) }
                t += dt
            }
        }
    }

    /// Synthetic shard: a rotated, glowing rect over the board — the same
    /// primitive SceneBuilder emits for real shards, at random position/spin.
    /// `glowMul` scales only the glow radius: the shape stays the same size
    /// while its quad (and thus per-instance pixel coverage) grows — the
    /// pure overdraw axis.
    static func addShards(_ list: inout DrawList, count: Int, layout: Layout,
                          glowMul: Float = 1) {
        for _ in 0..<count {
            let x = layout.boardX + Float.random(in: 0...layout.boardW)
            let y = layout.boardY + Float.random(in: 0...layout.boardH)
            let half = layout.cell * Float.random(in: 0.04...0.13)
            let rgb = hsv2rgb(Double.random(in: 0...1), 0.9, 1.0)
            list.add(.rect, center: SIMD2(x, y), halfShape: SIMD2(half, half),
                     corner: half * 0.4,
                     color: SIMD4(rgb.x, rgb.y, rgb.z, 1),
                     glowColor: rgb, glowStrength: 0.8,
                     glowRadius: layout.cell * 0.15 * glowMul,
                     rot: Float.random(in: 0...(2 * .pi)))
        }
    }

    /// Mean overdraw of a list: total quad area over screen area.
    static func overdrawFactor(_ list: DrawList) -> Double {
        var area = 0.0
        for inst in list.instances {
            area += Double(inst.a.z * 2 * inst.a.w * 2)
        }
        return area / Double(viewW * viewH)
    }

    // ---- Offscreen renderer -------------------------------------------------

    struct GPU {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let sampler: MTLSamplerState
        let atlasTex: MTLTexture
        let target: MTLTexture
        let libraryMs: Double
        let pipelineMs: Double
    }

    static func makeGPU() throws -> GPU {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("no Metal device")
        }

        // Compile the app's shader source, timed — this is the launch cost
        // the paper reports for the "shader as a runtime string" trade-off.
        var t0 = DispatchTime.now().uptimeNanoseconds
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let libraryMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

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
        t0 = DispatchTime.now().uptimeNanoseconds
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let pipelineMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: sdesc)!

        // 1x1 opaque stand-in for the glyph atlas (glyph quads sample alpha).
        let tdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let atlasTex = device.makeTexture(descriptor: tdesc)!
        var white: [UInt8] = [255, 255, 255, 255]
        atlasTex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                         withBytes: &white, bytesPerRow: 4)

        // The never-presented render target at iPhone 12 drawable size.
        let rdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(viewW), height: Int(viewH),
            mipmapped: false)
        rdesc.usage = [.renderTarget]
        rdesc.storageMode = .private
        let target = device.makeTexture(descriptor: rdesc)!

        return GPU(device: device, queue: queue, pipeline: pipeline,
                   sampler: sampler, atlasTex: atlasTex, target: target,
                   libraryMs: libraryMs, pipelineMs: pipelineMs)
    }

    /// Render `list` once, mirroring Renderer.render (fresh shared buffer each
    /// frame, same bindings). perDraw=false: one instanced call. perDraw=true:
    /// one draw call per instance (via baseInstance, same buffer/data).
    /// Returns (cpuEncodeMs, gpuMs).
    static func renderOnce(_ gpu: GPU, _ list: [GPUInstance],
                           perDraw: Bool) -> (cpu: Double, gpu: Double) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = gpu.target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let t0 = DispatchTime.now().uptimeNanoseconds
        let cmd = gpu.queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        var viewport = SIMD2<Float>(viewW, viewH)
        let buffer = gpu.device.makeBuffer(
            bytes: list, length: MemoryLayout<GPUInstance>.stride * list.count,
            options: .storageModeShared)
        enc.setRenderPipelineState(gpu.pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setFragmentTexture(gpu.atlasTex, index: 0)
        enc.setFragmentSamplerState(gpu.sampler, index: 0)
        if perDraw {
            for i in 0..<list.count {
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: 1,
                                   baseInstance: i)
            }
        } else {
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: list.count)
        }
        enc.endEncoding()
        cmd.commit()
        let cpuMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        cmd.waitUntilCompleted()
        return (cpuMs, (cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); return s[s.count / 2]
    }

    /// Warm up, then measure `frames` renders; returns median (cpuMs, gpuMs).
    static func measure(_ gpu: GPU, _ list: [GPUInstance], perDraw: Bool,
                        frames: Int = 60) -> (cpu: Double, gpu: Double) {
        for _ in 0..<10 { _ = renderOnce(gpu, list, perDraw: perDraw) }
        var cpus: [Double] = [], gpus: [Double] = []
        for _ in 0..<frames {
            let r = renderOnce(gpu, list, perDraw: perDraw)
            cpus.append(r.cpu); gpus.append(r.gpu)
        }
        return (median(cpus), median(gpus))
    }

    // ---- Main ---------------------------------------------------------------

    static func main() throws {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        GameModel.rows = 18
        let layout = makeLayout()
        GameModel.skyAbove = Double(layout.boardY / layout.cell)
        GameModel.skyBelow = Double((viewH - layout.boardY - layout.boardH)
                                    / layout.cell)
        let scene = SceneBuilder(atlas: GlyphAtlas())
        let gpu = try makeGPU()
        print("device: \(gpu.device.name)")
        print("shader library compile: \(String(format: "%.1f", gpu.libraryMs)) ms, "
              + "pipeline build: \(String(format: "%.1f", gpu.pipelineMs)) ms")

        // Overdraw-only mode: hold the instance count fixed and sweep the
        // glow radius, so per-quad pixel coverage (not primitive count) is
        // the independent variable. Writes its own CSV; touches no other
        // output files.
        if CommandLine.arguments.contains("overdraw") {
            print("capturing late frame for overdraw sweep...")
            let base = captureFrame(layout: layout, scene: scene) { g, _ in
                g.score >= 14
            }
            var csv = "glowMul,totalInstances,overdrawFactor,gpuMsMedian\n"
            for m: Float in [0.25, 0.5, 1, 2, 3, 4, 6] {
                var list = base
                addShards(&list, count: 4000, layout: layout, glowMul: m)
                let od = overdrawFactor(list)
                let r = measure(gpu, list.instances, perDraw: false)
                csv += "\(m),\(list.instances.count),"
                     + "\(String(format: "%.2f", od)),"
                     + "\(String(format: "%.3f", r.gpu))\n"
                print("glowMul=\(m): overdraw \(String(format: "%.1f", od))x "
                      + "-> gpu \(String(format: "%.3f", r.gpu)) ms")
            }
            try csv.write(toFile: outDir + "/gpu_overdraw_mac.csv",
                          atomically: true, encoding: .utf8)
            print("done; overdraw CSV in \(outDir)")
            return
        }

        // Three real frames as bases: early, late, death shatter.
        print("capturing real frames...")
        let early = captureFrame(layout: layout, scene: scene) { g, _ in g.score >= 2 }
        let late = captureFrame(layout: layout, scene: scene) { g, _ in g.score >= 14 }
        // Death shatter: keep the heaviest frame of the dying sequence.
        var shatterBest: DrawList? = nil
        while shatterBest == nil {
            let g = GameModel()
            var t = 0.0, starving = false
            while t < 300 && !g.isGameOver {
                if !starving && (g.snake.count >= 16 || g.score >= 25 || t > 120) { starving = true }
                if starving { g.foods.removeAll() } else { steer(g) }
                g.tick(1.0 / 60.0)
                if g.isDying {
                    let f = buildFrame(g, layout: layout, scene: scene, t: t)
                    if f.instances.count > (shatterBest?.instances.count ?? 0) {
                        shatterBest = f
                    }
                }
                t += 1.0 / 60.0
            }
        }
        let shatter = shatterBest!
        print("frames: early=\(early.instances.count) late=\(late.instances.count) "
              + "shatter=\(shatter.instances.count)")

        // Test A — stress sweep: late frame + k synthetic shards.
        var csv = "extraShards,totalInstances,gpuMsMedian,cpuEncodeMsMedian\n"
        for k in [0, 500, 1000, 2000, 4000, 8000, 16000, 32000, 64000, 128000] {
            var list = late
            addShards(&list, count: k, layout: layout)
            let m = measure(gpu, list.instances, perDraw: false)
            csv += "\(k),\(list.instances.count),"
                 + "\(String(format: "%.3f", m.gpu)),\(String(format: "%.3f", m.cpu))\n"
            print("stress k=\(k): \(list.instances.count) instances -> "
                  + "gpu \(String(format: "%.3f", m.gpu)) ms")
        }
        try csv.write(toFile: outDir + "/gpu_stress_mac.csv",
                      atomically: true, encoding: .utf8)

        // Test B — one instanced call vs N individual draw calls.
        var csv2 = "scene,instances,mode,gpuMsMedian,cpuEncodeMsMedian\n"
        var synthetic = late
        addShards(&synthetic, count: 4000, layout: layout)
        for (name, list) in [("early", early), ("late", late),
                             ("shatter", shatter), ("synthetic4k", synthetic)] {
            for perDraw in [false, true] {
                let m = measure(gpu, list.instances, perDraw: perDraw)
                let mode = perDraw ? "perDraw" : "instanced"
                csv2 += "\(name),\(list.instances.count),\(mode),"
                      + "\(String(format: "%.3f", m.gpu)),\(String(format: "%.3f", m.cpu))\n"
                print("\(name) [\(mode)]: cpu \(String(format: "%.3f", m.cpu)) ms, "
                      + "gpu \(String(format: "%.3f", m.gpu)) ms")
            }
        }
        try csv2.write(toFile: outDir + "/drawcalls_mac.csv",
                       atomically: true, encoding: .utf8)

        let info = "device: \(gpu.device.name)\n"
                 + "shaderLibraryCompileMs: \(String(format: "%.1f", gpu.libraryMs))\n"
                 + "pipelineBuildMs: \(String(format: "%.1f", gpu.pipelineMs))\n"
        try info.write(toFile: outDir + "/shader_compile_mac.txt",
                       atomically: true, encoding: .utf8)
        print("done; CSVs in \(outDir)")
    }
}
