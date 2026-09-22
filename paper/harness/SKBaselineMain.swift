import Foundation
import Dispatch
import Metal
import SpriteKit

// SpriteKit baseline benchmark (macOS, windowless). Renders a scene
// mirroring the game's late-game frame with Apple's native 2D framework,
// via SKRenderer into an offscreen texture — same resolution, pixel format,
// and timing methodology as the single-draw-call harness (GPUMain.swift),
// so the two stress curves are directly comparable.
//
// Fairness notes: idiomatic SpriteKit — textured sprites sharing a small set
// of pre-baked glow textures (the standard way to get glowing particles;
// per-node SKEffectNode blurs would be deliberately slow), a persistent node
// tree, and per-frame position/rotation updates for the shard sprites to
// mirror live particles. No physics, no actions, no view.
//
// Usage: sk_baseline <outputDir>

@main
struct SKBaseline {
    static let viewW = 1170.0, viewH = 2532.0

    // ---- Pre-baked textures (shared, idiomatic SpriteKit) -------------------

    /// Rounded square with a soft radial glow, tinted at build time.
    static func glowSquareTexture(hue: CGFloat) -> SKTexture {
        makeTexture(size: 64) { ctx in
            let color = NSColor(hue: hue, saturation: 0.9, brightness: 1, alpha: 1)
            let glow = [color.withAlphaComponent(0.5).cgColor,
                        color.withAlphaComponent(0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: glow, locations: [0, 1]) {
                ctx.drawRadialGradient(grad,
                    startCenter: CGPoint(x: 32, y: 32), startRadius: 8,
                    endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
            }
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 20, width: 24, height: 24),
                               cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }
    }

    /// Filled disc with a soft glow halo (pellets).
    static func glowCircleTexture(hue: CGFloat) -> SKTexture {
        makeTexture(size: 96) { ctx in
            let color = NSColor(hue: hue, saturation: 0.95, brightness: 1, alpha: 1)
            let glow = [color.withAlphaComponent(0.6).cgColor,
                        color.withAlphaComponent(0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: glow, locations: [0, 1]) {
                ctx.drawRadialGradient(grad,
                    startCenter: CGPoint(x: 48, y: 48), startRadius: 12,
                    endCenter: CGPoint(x: 48, y: 48), endRadius: 48, options: [])
            }
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: 26, y: 26, width: 44, height: 44))
        }
    }

    static func makeTexture(size: Int, draw: (CGContext) -> Void) -> SKTexture {
        let ctx = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return SKTexture(cgImage: ctx.makeImage()!)
    }

    // ---- Scene mirroring the game's late-game frame -------------------------

    /// Node counts mirror the census's late-game composition: background +
    /// board + ~270 lit grid segments + 40 body beads + 4 pellets + HUD.
    static func buildScene(shardTextures: [SKTexture],
                           shards: inout [SKSpriteNode], k: Int) -> SKScene {
        let scene = SKScene(size: CGSize(width: viewW, height: viewH))
        scene.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.02,
                                        blue: 0.10, alpha: 1)

        let board = SKSpriteNode(color: NSColor(white: 0, alpha: 0.45),
                                 size: CGSize(width: 966, height: 1580))
        board.position = CGPoint(x: viewW / 2, y: viewH / 2)
        scene.addChild(board)

        // Lit grid: thin line segments, tinted like the reactive grid.
        for i in 0..<270 {
            let horizontal = i % 2 == 0
            let seg = SKSpriteNode(
                color: NSColor(hue: 0.3 + 0.2 * CGFloat(i % 5) / 5,
                               saturation: 0.7, brightness: 0.8, alpha: 0.5),
                size: CGSize(width: horizontal ? 80 : 3,
                             height: horizontal ? 3 : 80))
            seg.position = CGPoint(x: 110 + Double(i % 11) * 88 + Double(i % 3),
                                   y: 480 + Double((i / 11) % 18) * 87)
            scene.addChild(seg)
        }

        // Snake body: overlapping bead sprites along a path.
        for i in 0..<40 {
            let bead = SKSpriteNode(texture: shardTextures[i % shardTextures.count])
            bead.size = CGSize(width: 84, height: 84)
            bead.position = CGPoint(x: 140 + Double(i) * 22,
                                    y: 1200 + 60 * sin(Double(i) * 0.4))
            scene.addChild(bead)
        }

        // Pellets.
        let pelletTex = glowCircleTexture(hue: 0.16)
        for i in 0..<4 {
            let p = SKSpriteNode(texture: pelletTex)
            p.size = CGSize(width: 90, height: 90)
            p.position = CGPoint(x: 200 + Double(i) * 220, y: 700 + Double(i % 2) * 400)
            scene.addChild(p)
        }

        // HUD.
        for (text, x) in [("6.9", 140.0), ("14/30", 980.0)] {
            let label = SKLabelNode(text: text)
            label.fontName = "Menlo-Bold"
            label.fontSize = 58
            label.position = CGPoint(x: x, y: viewH - 180)
            scene.addChild(label)
        }

        // Synthetic shards — the stress variable, matching GPUMain's sweep.
        shards.removeAll()
        for i in 0..<k {
            let s = SKSpriteNode(texture: shardTextures[i % shardTextures.count])
            let side = Double.random(in: 7...23)
            s.size = CGSize(width: side, height: side)
            s.position = CGPoint(x: Double.random(in: 102...1068),
                                 y: Double.random(in: 476...2056))
            s.zRotation = Double.random(in: 0...(2 * .pi))
            scene.addChild(s)
            shards.append(s)
        }
        return scene
    }

    // ---- Main ---------------------------------------------------------------

    static func main() throws {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { fatalError("no Metal device") }
        print("device: \(device.name)")

        let rdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(viewW), height: Int(viewH),
            mipmapped: false)
        rdesc.usage = [.renderTarget]
        rdesc.storageMode = .private
        let target = device.makeTexture(descriptor: rdesc)!

        let shardTextures = (0..<8).map { glowSquareTexture(hue: CGFloat($0) / 8) }

        var csv = "extraShards,totalNodes,gpuMsMedian,cpuMsMedian\n"
        for k in [0, 500, 1000, 2000, 4000, 8000, 16000, 32000, 64000] {
            var shards: [SKSpriteNode] = []
            let scene = buildScene(shardTextures: shardTextures, shards: &shards, k: k)
            let renderer = SKRenderer(device: device)
            renderer.scene = scene
            let nodes = 1 + scene.children.count   // scene + direct children

            var cpus: [Double] = [], gpus: [Double] = []
            var t = 0.0
            for frame in 0..<70 {
                // Live particles: every shard drifts and spins each frame.
                for s in shards {
                    s.position.x += CGFloat.random(in: -1...1)
                    s.position.y += CGFloat.random(in: -1...1)
                    s.zRotation += 0.02
                }
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = target
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0,
                                                                   blue: 0, alpha: 1)
                let t0 = DispatchTime.now().uptimeNanoseconds
                renderer.update(atTime: t)
                let cmd = queue.makeCommandBuffer()!
                renderer.render(withViewport: CGRect(x: 0, y: 0, width: viewW, height: viewH),
                                commandBuffer: cmd, renderPassDescriptor: rpd)
                cmd.commit()
                let cpuMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                cmd.waitUntilCompleted()
                if frame >= 10 {   // warmup
                    cpus.append(cpuMs)
                    gpus.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
                }
                t += 1.0 / 60.0
            }
            let gpuMed = gpus.sorted()[gpus.count / 2]
            let cpuMed = cpus.sorted()[cpus.count / 2]
            csv += "\(k),\(nodes),\(String(format: "%.3f", gpuMed)),"
                 + "\(String(format: "%.3f", cpuMed))\n"
            print("k=\(k): \(nodes) nodes -> gpu \(String(format: "%.3f", gpuMed)) ms, "
                  + "cpu \(String(format: "%.3f", cpuMed)) ms")
        }
        try csv.write(toFile: outDir + "/spritekit_stress_mac.csv",
                      atomically: true, encoding: .utf8)
        print("done; CSV in \(outDir)")
    }
}
