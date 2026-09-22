import Foundation
import Dispatch
import simd

// Headless data-collection harness for the paper's evaluation. Compiles the
// game's pure layers (GameModel + SceneBuilder, extracted verbatim from the
// app's main.swift by build.sh) for macOS and plays scripted games without
// any window, GPU, or phone. Emits one CSV row per simulated frame:
// instance counts (total and per shape kind) plus CPU scene-build time.
//
// Usage: harness [output.csv] [fxScale]

// ---- iPhone 12 geometry, reproduced from GameViewController -----------------
// Drawable 1170x2532 px at scale 3; safe-area top 47 pt; HUD offset 34 pt.
// Rows are fitted against the nominal 0.76h region, the visible layout uses
// 0.72h — same formulas as sizeGridToFillScreen/makeLayout in the app.
let viewW: Float = 1170, viewH: Float = 2532
let topInset: Float = (47 + 34) * 3

func fitRows() {
    let availH = viewH * 0.76 - topInset
    let cell = viewW / Float(GameModel.cols + 2)
    GameModel.rows = max(8, Int(availH / cell))
}

func makeLayout() -> Layout {
    let availH = viewH * 0.72 - topInset
    let cell = min(viewW / Float(GameModel.cols + 2), availH / Float(GameModel.rows))
    let boardW = cell * Float(GameModel.cols)
    let boardH = cell * Float(GameModel.rows)
    return Layout(viewSize: SIMD2(viewW, viewH), cell: cell, textUnit: viewW * 0.05,
                  boardX: (viewW - boardW) * 0.5,
                  boardY: topInset + (availH - boardH) * 0.5,
                  boardW: boardW, boardH: boardH)
}

// ---- Frame sampling ---------------------------------------------------------

fitRows()
let layout = makeLayout()
// Sky bounds for the finale, mirroring the host's injection.
GameModel.skyAbove = Double(layout.boardY / layout.cell)
GameModel.skyBelow = Double((layout.viewSize.y - layout.boardY - layout.boardH)
                            / layout.cell)
// Optional "Sparks" quality tier (second CLI argument).
if CommandLine.arguments.count > 2, let fx = Int(CommandLine.arguments[2]) {
    GameModel.fxScale = fx
}
let scene = SceneBuilder(atlas: GlyphAtlas())
let dt = 1.0 / 60.0
let kindNames = ["rect", "circle", "ring", "glyph", "bg", "frame"]

struct Sample {
    var total = 0
    var byKind = [Int](repeating: 0, count: 6)
    var buildMicros = 0.0
}

/// Build one frame's draw list with animation phases like the app's draw loop
/// (phases modulate sizes/colors and the lit-grid threshold, not the design).
func sampleFrame(_ g: GameModel, t: Double) -> Sample {
    let hueShift = (t * 0.008).truncatingRemainder(dividingBy: 1)
    let foodPulse = Float(0.5 + 0.5 * sin(t * 5.0))
    let headPulse = Float(0.5 + 0.5 * sin(t * 6.0))
    let pathPhase = Float(t.truncatingRemainder(dividingBy: 1))
    let fluidPhase = (t * 0.1 * g.effectiveSpeed).truncatingRemainder(dividingBy: 1)
    let t0 = DispatchTime.now().uptimeNanoseconds
    let list = scene.build(game: g, layout: layout, hueShift: hueShift,
                           foodPulse: foodPulse, headPulse: headPulse,
                           dashTint: 0, pathPhase: pathPhase,
                           fluidPhase: fluidPhase, scoreScale: 1, emberTime: t)
    let micros = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
    var s = Sample(total: list.instances.count, buildMicros: micros)
    for inst in list.instances {
        let k = Int(inst.b.w)
        if k >= 0 && k < 6 { s.byKind[k] += 1 }
    }
    return s
}

func gameState(_ g: GameModel) -> String {
    // Every run ends in the finale now: shatter (blocks popping), then the
    // fireworks show, then the panel (over).
    if g.isGameOver { return "over" }
    if !g.dyingCells.isEmpty { return "shatter" }
    if g.won { return "finale" }
    return "playing"
}

/// Greedy autopilot: aim at the nearest pellet; the model's own auto-steer
/// (the tap-to-target path) does the actual driving.
func steer(_ g: GameModel) {
    guard !g.isDying, !g.isGameOver, !g.won, let head = g.snake.last else { return }
    let target = g.foods.min {
        abs($0.point.x - head.x) + abs($0.point.y - head.y) <
        abs($1.point.x - head.x) + abs($1.point.y - head.y)
    }
    if let t = target { g.handle(.setDestination(t.point)) }
}

// ---- Scenarios --------------------------------------------------------------

var csv = "scenario,run,t,state,score,snakeLen,foods,particles,instances,"
        + kindNames.joined(separator: ",") + ",buildMicros\n"
var allRows: [(scenario: String, state: String, score: Int, sample: Sample)] = []

func record(_ scenario: String, _ run: Int, _ t: Double, _ g: GameModel, _ s: Sample) {
    let st = gameState(g)
    csv += "\(scenario),\(run),\(String(format: "%.3f", t)),\(st),\(g.score),"
         + "\(g.snake.count),\(g.foods.count),\(g.particles.count),\(s.total),"
         + s.byKind.map(String.init).joined(separator: ",")
         + ",\(String(format: "%.1f", s.buildMicros))\n"
    allRows.append((scenario, st, g.score, s))
}

// ---- Golden-trace mode ------------------------------------------------------
// `harness trace <out> [seed]`: a fully deterministic scripted run (seeded
// Rand, fixed dt, greedy steer for 600 frames, then forced starvation into
// the finale). Every frame logs its instance count + per-kind histogram;
// the first 10 frames and every 20th dump all 24 floats of every instance.
// The Kotlin port replays the identical script and must match.
if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "trace" {
    let outPath = CommandLine.arguments[2]
    let seedVal = CommandLine.arguments.count > 3
        ? (UInt64(CommandLine.arguments[3]) ?? 12345) : 12345
    Rand.seed(seedVal)
    GameModel.fxScale = 1
    var trace = "SNAKETRACE v1 seed=\(seedVal) rows=\(GameModel.rows) "
              + "cell=\(String(format: "%.6e", layout.cell))\n"
    let g = GameModel()
    var frame = 0
    while frame < 1500 {
        if frame >= 600 { g.foods.removeAll() } else { steer(g) }
        g.tick(dt)
        let t = Double(frame) / 60.0
        let hueShift = (t * 0.008).truncatingRemainder(dividingBy: 1)
        let list = scene.build(game: g, layout: layout, hueShift: hueShift,
                               foodPulse: Float(0.5 + 0.5 * sin(t * 5.0)),
                               headPulse: Float(0.5 + 0.5 * sin(t * 6.0)),
                               dashTint: 0,
                               pathPhase: Float(t.truncatingRemainder(dividingBy: 1)),
                               fluidPhase: (t * 0.1 * g.effectiveSpeed)
                                   .truncatingRemainder(dividingBy: 1),
                               scoreScale: 1, emberTime: t)
        var hist = [Int](repeating: 0, count: 6)
        for inst in list.instances { hist[Int(inst.b.w)] += 1 }
        trace += "F \(frame) \(list.instances.count) "
               + hist.map(String.init).joined(separator: " ") + "\n"
        if frame < 10 || frame % 20 == 0 {
            for inst in list.instances {
                let f: [Float] = [inst.a.x, inst.a.y, inst.a.z, inst.a.w,
                                  inst.b.x, inst.b.y, inst.b.z, inst.b.w,
                                  inst.color.x, inst.color.y, inst.color.z, inst.color.w,
                                  inst.glow.x, inst.glow.y, inst.glow.z, inst.glow.w,
                                  inst.uv.x, inst.uv.y, inst.uv.z, inst.uv.w,
                                  inst.misc.x, inst.misc.y, inst.misc.z, inst.misc.w]
                trace += "I " + f.map { String(format: "%.9e", $0) }
                    .joined(separator: " ") + "\n"
            }
        }
        if g.isGameOver { break }
        frame += 1
    }
    trace += "END \(frame) score=\(g.score)\n"
    try trace.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("trace: \(frame + 1) frames, score \(g.score), -> \(outPath)")
    exit(0)
}

// Scenario 1 — full autopiloted games: calm early play through unlocks,
// severances, possibly a win (fireworks) or a natural starvation death.
for run in 0..<5 {
    let g = GameModel()
    var t = 0.0
    while t < 240 {
        steer(g)
        g.tick(dt)
        record("gameplay", run, t, g, sampleFrame(g, t: t))
        // A win freezes the model (isGameOver in the same eat), so the frame
        // just recorded is the whole celebration; nothing more to capture.
        if g.isGameOver { break }
        t += dt
    }
    print("gameplay run \(run): ended t=\(String(format: "%.1f", t))s "
          + "score=\(g.score) len=\(g.snake.count) state=\(gameState(g))")
}

// Scenario 2 — forced death shatter with a long body: feed until the snake is
// long (or 120 s), then remove every pellet each frame so starvation is
// guaranteed. The isDying frames are the renderer's worst case.
for run in 0..<3 {
    let g = GameModel()
    var t = 0.0
    var starving = false
    while t < 300 {
        // Starve once the body is long — or before the autopilot can win.
        if !starving && (g.snake.count >= 18 || g.score >= 25 || t > 120) { starving = true }
        if starving { g.foods.removeAll() } else { steer(g) }
        g.tick(dt)
        record("shatter", run, t, g, sampleFrame(g, t: t))
        if g.isGameOver { break }
        t += dt
    }
    print("shatter run \(run): ended t=\(String(format: "%.1f", t))s "
          + "len at start of death captured, state=\(gameState(g))")
}

// ---- Output -----------------------------------------------------------------

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "headless_counts.csv"
try csv.write(toFile: outPath, atomically: true, encoding: .utf8)

func percentile(_ sorted: [Int], _ p: Double) -> Int {
    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

/// Paper-facing buckets: early (<5, one pellet kind), mid (5–15), late (16+,
/// all five kinds), plus the special states.
func bucket(_ r: (scenario: String, state: String, score: Int, sample: Sample)) -> String {
    if r.state != "playing" { return r.state }
    if r.score < 5 { return "early" }
    if r.score < 16 { return "mid" }
    return "late"
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, w - s.count))
    return right ? fill + s : s + fill
}

print("\nrows: \(allRows.count)  grid: \(GameModel.cols)x\(GameModel.rows)  "
      + "cell: \(String(format: "%.1f", layout.cell))px\n")
print(pad("bucket", 8) + ["frames", "mean", "p95", "max", "maxKB/frm", "buildUs"]
      .map { pad($0, 10, right: true) }.joined())
for b in ["early", "mid", "late", "shatter", "finale", "over"] {
    let rows = allRows.filter { bucket($0) == b }
    guard !rows.isEmpty else { continue }
    let counts = rows.map { $0.sample.total }.sorted()
    let mean = counts.reduce(0, +) / counts.count
    let mx = counts.last ?? 0
    let us = rows.map { $0.sample.buildMicros }.reduce(0, +) / Double(rows.count)
    let cells = ["\(counts.count)", "\(mean)", "\(percentile(counts, 0.95))", "\(mx)",
                 String(format: "%.1f", Double(mx) * 96.0 / 1024.0),
                 String(format: "%.1f", us)]
    print(pad(b, 8) + cells.map { pad($0, 10, right: true) }.joined())
}

// Per-kind breakdown at the overall peak frame — the paper's table row.
if let peak = allRows.max(by: { $0.sample.total < $1.sample.total }) {
    print("\npeak frame (\(peak.scenario), \(peak.state)): \(peak.sample.total) instances")
    for (i, n) in peak.sample.byKind.enumerated() where n > 0 {
        print("  " + pad(kindNames[i], 7) + pad("\(n)", 6, right: true))
    }
}
print("\nCSV written to \(outPath)")
