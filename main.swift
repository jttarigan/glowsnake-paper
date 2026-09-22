import UIKit
import MetalKit
import simd

// =============================================================================
// SnakeBuild — pure-Metal rendering.
//
// Architecture (the seam, not the API, is what makes this port to Android):
//
//   Simulation   GameModel — pure logic, zero render/UI deps  → Kotlin 1:1
//   Scene        SceneBuilder turns model state into a flat draw-list of
//                primitives (rounded-rect / circle / ring / frame / glyph)  → Kotlin 1:1
//   Renderer     ONE instanced Metal pipeline; every primitive — including
//                HUD text — is a unit quad shaded by SDF in the fragment stage
//   Input        UIKit gestures → InputIntent → GameModel  (intent type ports)
//   Host         UIKit view controller hosting an MTKView   (per-platform shell)
//
// Only the renderer host, the gesture recognizers, and the shader source are
// platform-specific. Everything above the renderer is plain data + arithmetic.
// =============================================================================

// MARK: - Visual effects switchboard
//
// Every cosmetic upgrade is gated behind one of these flags. Flip any to
// `false` to remove that effect instantly; the game falls back to its plain
// look with no other changes needed.
enum FX {
    static let animatedBackground = true   // drifting, color-cycling backdrop
    static let neonGrid           = true   // glowing grid lines + neon board frame
    static let eatParticles       = true   // colorful confetti burst on eating
    static let reactiveMood       = true   // score-driven bg hue + eat flash
    static let finaleFireworks    = true   // end-of-run fireworks show
    static let ambientEmbers      = true   // drifting full-screen dust motes
    // Experimental (may be backtracked): every ember also lights the grid —
    // hundreds of permanent dim lights. Flip to false to fully revert.
    static let emberLights        = true
    // Frame profiler: on-screen "cpuMs/gpuMs instances" readout, plus a CSV
    // of every frame written to Documents when a run ends.
    static let debugHud           = true
    // Benchmarking: every finale fires the full 30-rocket show regardless of
    // score. WARNING: also affects the headless census harness (it compiles
    // this file's flags) — flip off before regenerating paper census data.
    static let benchMaxFinale     = true
    // (The old rainbowSnake gradient was replaced by diet coloring: each
    // segment wears the color of the food that created it.)
}

// MARK: - Control scheme
//
// Experimental D-pad: the board takes the top 4/5 of the screen and a
// gamepad-style cross of buttons fills the bottom fifth; tap-to-target
// steering is disabled. Flip `dpad` to false to fully revert — the board
// reclaims the whole height, buttons vanish, tap-to-target returns.
enum Controls {
    static let dpad = true
}

// MARK: - Deterministic randomness
//
// All randomness in the pure layers flows through Rand so a harness can
// seed it and replay runs deterministically — and so the Kotlin port can
// reproduce bit-identical streams. SplitMix64 with explicit range mapping;
// no stdlib RNG is involved, keeping Swift and Kotlin in lockstep.
enum Rand {
    static var state: UInt64 = {
        var g = SystemRandomNumberGenerator(); return g.next()
    }()
    static func seed(_ s: UInt64) { state = s }

    static func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1): the top 53 bits, scaled.
    static func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    static func d(_ r: ClosedRange<Double>) -> Double {
        r.lowerBound + unit() * (r.upperBound - r.lowerBound)
    }
    static func i(_ r: Range<Int>) -> Int {
        r.lowerBound + Int(unit() * Double(r.count))
    }
    static func i(_ r: ClosedRange<Int>) -> Int {
        i(r.lowerBound..<(r.upperBound + 1))
    }
    static func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[i(0..<a.count)] }
    static func shuffled<T>(_ a: [T]) -> [T] {
        var c = a
        var k = c.count - 1
        while k >= 1 {
            c.swapAt(k, i(0..<(k + 1)))
            k -= 1
        }
        return c
    }
}

// MARK: - Model

struct Point: Equatable {
    var x: Int
    var y: Int
}

/// A fading marker left along the head's path, forming a glowing wake.
struct TrailMark: Identifiable {
    let id: Int
    let point: Point
    var age: Double
}

/// An expanding circular shockwave spawned where food was eaten.
struct Ripple: Identifiable {
    let id: Int
    let center: Point
    /// Hue of the wave (the eaten food's color); < 0 renders white-hot
    /// (used by severance shockwaves).
    let hue: Double
    var age: Double
}

/// The four food kinds. Every pill scores +1 (the win currency) and resets
/// the countdown; each adds its own burden. Kinds unlock as score milestones.
/// Each carries a single source-of-truth hue that drives the pellet, its
/// shards, its shockwave, and the grid light it casts.
/// The five pellets, numbered by appearance. Cyberpunk palette:
/// 1 grow #FDF500 (neon yellow), 2 speed #37EBF3 (cyan), 3 scatter #00FF90
/// (spring green), 4 time #9201CB (purple), 5 penalty #FF007A (hot pink).
enum FoodKind: CaseIterable {
    case grow      // 1, neon yellow: +1 tail segment (from the start)
    case speed     // 2, cyan:        +5% move speed, permanent (unlocks @5)
    case scatter   // 3, acid mint:   toggles restless pellets — everything on
                   //                 the board hops to a neighbor cell each
                   //                 second until another 3 is eaten (@8)
    case time      // 4, purple:      countdown drains 25% faster until next eat (@12)
    case penalty   // 5, hot pink:    +5 segments, +50% speed, countdown cut to
                   //                 5s — all exploding away on the next eat (@16)

    var hue: Double {
        switch self {
        case .grow:    return 0.161   // #FDF500
        case .speed:   return 0.507   // #37EBF3
        case .scatter: return 0.427   // #00FF90
        case .time:    return 0.786   // #9201CB
        case .penalty: return 0.920   // #FF007A
        }
    }

    /// A random shade near this kind's color — identical effect, varied
    /// paint for the pellet, its shards, and the body's fluid mix.
    func randomShade() -> Double {
        switch self {
        case .grow:    return Rand.d(0.130...0.192)
        case .speed:   return Rand.d(0.470...0.545)
        case .scatter: return Rand.d(0.395...0.455)
        case .time:    return Rand.d(0.750...0.825)
        case .penalty: return Rand.d(0.890...0.955)
        }
    }
}

struct Food {
    var point: Point
    var kind: FoodKind
    /// This pellet's specific shade within its kind's color family.
    var shade: Double = 0
    /// Seconds since (re)spawn — pellets explode and relocate when it runs out.
    var age: Double = 0
}

/// A shard of the eaten food, flung outward. Position and velocity are in
/// cell units (1 = one grid cell). All shards share the game's rounded-square
/// look and the food's hue family; only size, lifetime, and tumble vary.
struct Particle: Identifiable {
    let id: Int
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    let hue: Double
    var age: Double
    let lifetime: Double    // seconds; randomized per particle
    let size: Double        // base size as a fraction of a cell
    var angle: Double       // current rotation in radians
    let spin: Double        // radians/sec, signed
    // Firework sparks fall and twinkle; everything else leaves the defaults.
    var gravity: Double = 0 // cells/s² downward
    var twinkle: Bool = false
}

/// One scheduled firework of the finale: where and when it bursts, in the
/// same continuous cell-space the particles use (y extends beyond the board
/// into the HUD and pad regions — the whole screen is the sky).
struct Firework {
    let ignition: Double    // seconds after the show starts
    let x: Double
    let y: Double
    let shade: Double
    var exploded = false
}

enum Direction {
    case up, down, left, right

    var delta: Point {
        switch self {
        case .up:    return Point(x: 0, y: -1)
        case .down:  return Point(x: 0, y: 1)
        case .left:  return Point(x: -1, y: 0)
        case .right: return Point(x: 1, y: 0)
        }
    }

    /// True if `other` is the direct opposite of `self`.
    func isOpposite(of other: Direction) -> Bool {
        switch (self, other) {
        case (.up, .down), (.down, .up), (.left, .right), (.right, .left):
            return true
        default:
            return false
        }
    }
}

/// Platform-agnostic player intents. The host translates raw gestures into
/// these; the model never sees a `UIGestureRecognizer`. Android feeds the same
/// intents from `onTouchEvent`.
enum InputIntent {
    /// Aim the snake at a grid cell; it auto-steers there, then glides straight.
    case setDestination(Point)
    /// Steer one of four ways (D-pad); ignored if it would reverse.
    case turn(Direction)
    case dash
    case restart
}

final class GameModel {
    // 11 playable columns; the layout sizes cells as if there were 13, so the
    // board sits one cell in from each screen edge. The host extends `rows`
    // once at startup so the board fills the screen below the HUD (18 is the
    // fallback if that sizing never runs).
    static let cols = 11
    static var rows = 18

    /// Seconds between moves at normal speed, and while dashing (2x faster).
    /// Both shrink as blue food stacks `speedFactor` (+5% each, capped below).
    static let baseMoveInterval: Double = 0.15
    static let dashMoveInterval: Double = 0.075
    static let maxSpeedFactor: Double = 3.0
    /// The countdown: hits 0 → game over. Eating any pill resets it to this
    /// (red resets it to only `redCountdown`); yellow makes it drain
    /// `fastDrainRate`× faster until the next eat.
    static let starveLimit: Double = 10
    static let fastDrainRate: Double = 1.25
    /// Reaching this score wins the game.
    static let winScore = 30
    /// Kinds unlock at these scores (pellets 2, 3, 4, 5).
    static let unlockThresholds: [(score: Int, kind: FoodKind)] =
        [(5, .speed), (8, .scatter), (12, .time), (16, .penalty)]
    /// Red rush: bonus segments, speed multiplier, and the shortened
    /// countdown; on the next eat the bonus segments explode one every
    /// `rushPopInterval` seconds in shuffled order.
    static let redRushSegments = 5
    static let redRushSpeedBoost: Double = 1.5
    static let redCountdown: Double = 5
    static let rushPopInterval: Double = 0.05
    /// Finale fireworks: one per score point. The show's total length (last
    /// sparkle out) interpolates from 3s at 1 firework to 10s at 30, and the
    /// ignition window over which rockets launch scales alongside.
    static let finaleMinDuration: Double = 3
    static let finaleMaxDuration: Double = 10
    static let finaleMinWindow: Double = 0.4
    static let finaleMaxWindow: Double = 3
    static let streakDuration: Double = 0.35
    static let sparkGravity: Double = 3.2
    /// Sky bounds in cell units, injected by the host once layout is known:
    /// how many cells of screen extend above and below the board.
    static var skyAbove: Double = 2.5
    static var skyBelow: Double = 7.0
    /// A new food spawns on this cadence, up to `maxFoods` on the board.
    static let foodSpawnInterval: Double = 2
    static let maxFoods = 4
    /// A pellet explodes and relocates after this long; it starts blipping
    /// at `foodWarnTime` to telegraph the fuse.
    static let foodLifetime: Double = 5
    static let foodWarnTime: Double = 3
    /// While restless mode is on (pellet 3's toggle), every pellet hops to a
    /// random open neighbor cell on this cadence — discrete, synchronized.
    static let pelletHopInterval: Double = 1
    /// Neutral mint worn by the starting segments (before any diet history).
    static let baseSegmentHue: Double = 0.42
    /// A dash lasts this long and can be re-triggered this often.
    static let dashDuration: Double = 0.5
    static let dashCooldown: Double = 2
    /// After a dash ends, its glow fades to nothing over this many seconds.
    static let dashFadeDuration: Double = 0.6
    /// Each head-trail marker fades out over this many seconds.
    static let trailLifetime: Double = 0.5
    /// An eat-ripple expands and fades over this many seconds, its wavefront
    /// traveling `rippleTravel` cells outward from where the food was eaten.
    static let rippleLifetime: Double = 1.5
    static let rippleTravel: Double = 9.5
    /// Shards: burst size and how quickly pieces lose speed (per-second
    /// exponential damping). Lifetime scales with shard size — the larger the
    /// piece, the longer it lingers, up to ~10s of slow ember fade-out.
    static let particleCount = 56
    /// The "Sparks" quality dial (options menu): multiplies the particle
    /// count of every cosmetic burst — eats, severances, shatter, shimmers,
    /// fuse explosions, finale fireworks. Never touches gameplay.
    static var fxScale = 1
    static let particleLifeSmall: Double = 2
    static let particleLifeLarge: Double = 10
    static let particleDrag: Double = 1.6
    /// Shards are shoved away by the snake's body — same-pole-magnet feel.
    /// Reach in cells, and acceleration scale (cells/s²) near contact.
    static let particleRepelRadius: Double = 1.4
    static let particleRepelForce: Double = 30
    static let eatFlashDuration: Double = 0.4

    var snake: [Point] = []
    /// `snake` as it was before the most recent step. The render layer glides
    /// each segment from its previous cell to its current one, so segments
    /// never teleport; logic stays fully cell-based.
    private(set) var prevSnake: [Point] = []
    /// Per-segment hues, aligned with `snake` (tail..head): each segment wears
    /// the color of the food that created it. Stripes ride the body — a plain
    /// move never touches this array; growth inserts at the tail end.
    var segmentHues: [Double] = []
    /// True while yellow's curse is active: countdown drains 25% faster until
    /// the next eat (HUD glows the countdown yellow).
    var fastDrain = false
    /// True during a red rush: +5 bonus segments and +50% speed, all of which
    /// expire (explosively) on the next eat.
    var redRush = false
    /// True when the game ended by reaching the win score.
    var won = false
    /// Death sequence: when the countdown hits 0 the body freezes and breaks
    /// into loose blocks (`dyingCells`) that explode one by one in random
    /// order; the Game Over panel appears 2s after the last one.
    var isDying = false
    var dyingCells: [(point: Point, hue: Double)] = []
    private var dyingTimer: Double = 0
    /// The finale show: scheduled fireworks and the clock they ignite by.
    /// Runs after the shatter completes; the panel appears when the clock
    /// passes `finaleDuration` and the last twinkling spark has died.
    var fireworks: [Firework] = []
    var finaleClock: Double = 0
    private var finaleDuration: Double = 0
    var foods: [Food] = []
    /// Pellet 3's toggle: while true, every pellet hops each second.
    var pelletsRestless = false
    private var pelletHopTimer: Double = 0
    /// Movement speed multiplier grown by pellet 2 (1 = base speed).
    var speedFactor: Double = 1
    /// Cell the player last tapped; the snake auto-steers toward it. Cleared
    /// (nil) once reached, after which the snake keeps gliding straight.
    var destination: Point? = nil
    var score: Int = 0
    var isGameOver: Bool = false
    /// Bumps every time the head severs the body; cumulative across games so
    /// the host can detect new events by comparing to its last-seen value.
    var severanceCount: Int = 0
    /// Seconds left before starving; refilled on eating.
    var timeRemaining: Double = 10
    /// 0→1 fraction of the way through the current move interval; the render
    /// layer eases this to slide segments between cells.
    var moveProgress: Double {
        let interval = (dashTimeRemaining > 0 ? GameModel.dashMoveInterval
                                              : GameModel.baseMoveInterval) / effectiveSpeed
        return min(1, max(0, moveAccumulator / interval))
    }
    /// True when a dash can be triggered (drives the head's pulsing glow).
    var dashReady: Bool = true
    /// True while a dash is active (drives the yellow color tint).
    var isDashing: Bool = false
    /// Trail-glow intensity (1 while dashing, decaying to 0 afterward).
    var dashGlow: Double = 0
    /// Fading markers left where the tail vacates each cell (a glowing wake).
    var trail: [TrailMark] = []
    /// Active eat-ripples, expanding and fading.
    var ripples: [Ripple] = []
    /// Active confetti particles from eating.
    var particles: [Particle] = []
    /// Full-screen eat-flash intensity (1 on eat, decaying to 0).
    var eatFlash: Double = 0

    private var direction: Direction = .right
    /// Direction queued from the most recent turn input; applied at the next step.
    private var pendingDirection: Direction = .right
    /// Time banked toward the next move; a move fires each time it crosses the interval.
    private var moveAccumulator: Double = 0
    /// Seconds left in the current dash (0 when not dashing).
    private var dashTimeRemaining: Double = 0
    /// Seconds left until a dash can be triggered again.
    private var dashCooldownRemaining: Double = 0
    /// Counts down to the next food spawn.
    private var foodSpawnTimer: Double = 0
    /// Growth waiting to materialize: each step with pending growth keeps the
    /// tail and inserts the next queued hue (green queues 1, red queues 5).
    private var pendingGrowth = 0
    private var pendingHues: [Double] = []
    /// Staged red-rush teardown: bonus segments pop one per `rushPopInterval`,
    /// bursting at pre-shuffled cells.
    private var rushPopsRemaining = 0
    private var rushPopTimer: Double = 0
    private var rushBurstCells: [Point] = []
    /// Highest score reached this run. Kind unlocks ratchet on this, so
    /// severance losses set back the win progress without de-evolving the
    /// board's spawn pool.
    private(set) var highWater = 0
    /// Kinds spawnable now (green always; others by high-water milestone).
    var unlockedKinds: [FoodKind] {
        [.grow] + GameModel.unlockThresholds.filter { highWater >= $0.score }.map { $0.kind }
    }
    /// Shades of the last 5 meals, oldest first — the body's fluid palette.
    private(set) var recentMeals: [Double] = []
    /// Effective speed: permanent blue stacking × the red rush boost.
    var effectiveSpeed: Double {
        speedFactor * (redRush ? GameModel.redRushSpeedBoost : 1)
    }
    /// Monotonic id sources for trail markers, ripples, and particles.
    private var trailCounter = 0
    private var rippleCounter = 0
    private var particleCounter = 0

    init() {
        reset()
    }

    /// Single entry point for player input — keeps the model free of UI types.
    func handle(_ intent: InputIntent) {
        switch intent {
        case .setDestination(let p): setDestination(p)
        case .turn(let d):           turn(d)
        case .dash:                  triggerDash()
        case .restart:               if isGameOver { reset() }
        }
    }

    func reset() {
        let midY = GameModel.rows / 2
        // Length 3, heading right; head is the last element.
        snake = [Point(x: 3, y: midY), Point(x: 4, y: midY), Point(x: 5, y: midY)]
        prevSnake = snake
        segmentHues = Array(repeating: GameModel.baseSegmentHue, count: snake.count)
        fastDrain = false
        redRush = false
        won = false
        isDying = false
        dyingCells = []
        dyingTimer = 0
        fireworks = []
        finaleClock = 0
        finaleDuration = 0
        pendingGrowth = 0
        pendingHues = []
        highWater = 0
        recentMeals = []
        rushPopsRemaining = 0
        rushPopTimer = 0
        rushBurstCells = []
        direction = .right
        pendingDirection = .right
        destination = nil
        score = 0
        isGameOver = false
        timeRemaining = GameModel.starveLimit
        moveAccumulator = 0
        dashTimeRemaining = 0
        dashCooldownRemaining = 0
        dashReady = true
        isDashing = false
        dashGlow = 0
        trail = []
        trailCounter = 0
        ripples = []
        rippleCounter = 0
        particles = []
        particleCounter = 0
        eatFlash = 0
        foods = []
        pelletsRestless = false
        pelletHopTimer = 0
        speedFactor = 1
        foodSpawnTimer = GameModel.foodSpawnInterval
        spawnFood()
    }

    /// Set the cell the snake should head toward (clamped to the board).
    func setDestination(_ p: Point) {
        guard !isGameOver else { return }
        let x = min(max(p.x, 0), GameModel.cols - 1)
        let y = min(max(p.y, 0), GameModel.rows - 1)
        destination = Point(x: x, y: y)
    }

    /// Choose the next heading toward `destination`, L-shape style: close the
    /// horizontal gap first, then the vertical. Honors the no-180°-reversal
    /// rule — if the preferred move would reverse, it takes the other axis
    /// instead; if neither is legal (target directly behind), the heading is
    /// left unchanged so the snake glides straight until it can turn or is
    /// retargeted. No destination / already arrived → heading unchanged.
    private func steerTowardDestination() {
        guard let dest = destination, let head = snake.last else { return }
        if head == dest { destination = nil; return }

        // Preferred moves in priority order: horizontal first, then vertical.
        var preferred: [Direction] = []
        if dest.x != head.x { preferred.append(dest.x > head.x ? .right : .left) }
        if dest.y != head.y { preferred.append(dest.y > head.y ? .down : .up) }

        for dir in preferred where !dir.isOpposite(of: direction) {
            pendingDirection = dir
            return
        }
    }

    /// Steer one of four ways; ignored if it would reverse into the neck.
    /// Clears any tap destination so D-pad input always wins.
    func turn(_ dir: Direction) {
        guard !isGameOver, !isDying, !dir.isOpposite(of: direction) else { return }
        destination = nil
        pendingDirection = dir
    }

    /// Begin a 0.5s dash (2x speed) if the ability is off cooldown.
    func triggerDash() {
        guard !isGameOver, dashCooldownRemaining <= 0, dashTimeRemaining <= 0 else { return }
        dashTimeRemaining = GameModel.dashDuration
        dashCooldownRemaining = GameModel.dashCooldown
        dashReady = false
    }

    /// Advance all timers by `dt` seconds, firing moves as they come due.
    func tick(_ dt: Double) {
        guard !isGameOver else { return }

        // The finale: the body shatters at full speed (one block per 0.05s,
        // random order); once the last block is gone, the fireworks show
        // begins — rockets ignite on their scheduled times, and the score
        // panel appears when the show's clock runs out and the last
        // twinkling spark has died.
        if isDying {
            ageEffects(dt)
            if !dyingCells.isEmpty {
                dyingTimer += dt
                while dyingTimer >= GameModel.rushPopInterval && !dyingCells.isEmpty {
                    dyingTimer -= GameModel.rushPopInterval
                    let victim = dyingCells.remove(at: Rand.i(0..<dyingCells.count))
                    // The shatter goes big: triple the shards, wilder sizes,
                    // and shades straying well off the segment's color.
                    burst(at: victim.point, hue: victim.hue, count: 36,
                          sizes: 0.04...0.26, hueSpread: 0.12, speeds: 1.5...12)
                }
            } else {
                finaleClock += dt
                for i in fireworks.indices
                where !fireworks[i].exploded && fireworks[i].ignition <= finaleClock {
                    fireworks[i].exploded = true
                    igniteFirework(fireworks[i])
                }
                if finaleClock >= finaleDuration
                    && !particles.contains(where: { $0.twinkle }) {
                    isGameOver = true
                }
            }
            return
        }

        // The countdown (yellow's curse drains it 25% faster). There is no
        // losing: at zero the run simply ends — the body shatters and the
        // score buys the fireworks show.
        timeRemaining -= dt * (fastDrain ? GameModel.fastDrainRate : 1)
        if timeRemaining <= 0 {
            timeRemaining = 0
            beginFinale()
            return
        }

        // Staged red-rush teardown: expired bonus segments pop off the tail
        // one by one, each bursting at a pre-shuffled cell.
        if rushPopsRemaining > 0 {
            rushPopTimer += dt
            while rushPopTimer >= GameModel.rushPopInterval && rushPopsRemaining > 0 {
                rushPopTimer -= GameModel.rushPopInterval
                rushPopsRemaining -= 1
                if let cell = rushBurstCells.popLast() {
                    burst(at: cell, hue: FoodKind.penalty.hue, count: 10)
                }
                if snake.count > 1 {
                    snake.removeFirst()
                    segmentHues.removeFirst()
                }
            }
        } else {
            rushPopTimer = 0
        }

        // Dash and cooldown countdowns.
        dashTimeRemaining = max(0, dashTimeRemaining - dt)
        dashCooldownRemaining = max(0, dashCooldownRemaining - dt)
        dashReady = dashCooldownRemaining <= 0
        isDashing = dashTimeRemaining > 0
        // Hold the glow at full while dashing, then let it fade out gradually.
        if dashTimeRemaining > 0 {
            dashGlow = 1
        } else {
            dashGlow = max(0, dashGlow - dt / GameModel.dashFadeDuration)
        }

        ageEffects(dt)

        // Spawn cadence: a new random food every 2s, up to 4 on the board.
        foodSpawnTimer -= dt
        if foodSpawnTimer <= 0 {
            if foods.count < GameModel.maxFoods { spawnFood() }
            foodSpawnTimer = GameModel.foodSpawnInterval
        }

        // Pellets have a 5s fuse: on expiry they burst into shards of their
        // color and respawn at a fresh cell (same kind, fuse rewound).
        for i in foods.indices {
            foods[i].age += dt
            if foods[i].age >= GameModel.foodLifetime {
                explodeFood(foods[i])
                if let cell = freeCell() {
                    foods[i].point = cell
                    spawnShimmer(at: cell, hue: foods[i].shade)
                }
                foods[i].age = 0
            }
        }

        // Restless mode (pellet 3's toggle): once a second, every pellet hops
        // to a random open neighbor cell — a discrete, synchronized scatter.
        // Blocked = board edge (pellets don't wrap), snake, or another pellet.
        if pelletsRestless {
            pelletHopTimer += dt
            if pelletHopTimer >= GameModel.pelletHopInterval {
                pelletHopTimer -= GameModel.pelletHopInterval
                for i in foods.indices {
                    let f = foods[i]
                    let open = [Direction.up, .down, .left, .right].compactMap {
                        dir -> Point? in
                        let n = Point(x: f.point.x + dir.delta.x,
                                      y: f.point.y + dir.delta.y)
                        guard n.x >= 0, n.x < GameModel.cols,
                              n.y >= 0, n.y < GameModel.rows,
                              !snake.contains(n),
                              !foods.contains(where: { $0.point == n }) else { return nil }
                        return n
                    }
                    if let hop = Rand.pick(open) { foods[i].point = hop }
                }
            }
        } else {
            pelletHopTimer = 0
        }

        // Fire moves each time the banked time crosses the current interval.
        let interval = (dashTimeRemaining > 0 ? GameModel.dashMoveInterval
                                              : GameModel.baseMoveInterval) / effectiveSpeed
        moveAccumulator += dt
        while moveAccumulator >= interval && !isGameOver {
            moveAccumulator -= interval
            step()
        }
    }

    private func step() {
        guard !isGameOver else { return }
        prevSnake = snake
        steerTowardDestination()
        direction = pendingDirection

        guard var head = snake.last else { return }
        head.x += direction.delta.x
        head.y += direction.delta.y

        // Walls wrap: leaving one edge re-enters from the opposite edge.
        head.x = (head.x + GameModel.cols) % GameModel.cols
        head.y = (head.y + GameModel.rows) % GameModel.rows

        // Growth queued by eating (green: 1, red: 5) materializes one segment
        // per step: the tail stays put and the queued hue joins at the tail.
        // Otherwise the tail vacates its cell first, so re-entering it is not
        // a hit. (Stripes ride the body — a plain move leaves hues untouched.)
        if pendingGrowth > 0 {
            pendingGrowth -= 1
            segmentHues.insert(pendingHues.isEmpty ? GameModel.baseSegmentHue
                                                   : pendingHues.removeFirst(), at: 0)
        } else if let tail = snake.first {
            trail.append(TrailMark(id: trailCounter, point: tail, age: 0))
            trailCounter += 1
            snake.removeFirst()
        }

        // Running into your own body doesn't end the game: it severs the snake
        // at the hit segment. That segment and everything tailward of it (the
        // half without the head) is destroyed in a burst.
        if let hit = snake.firstIndex(of: head) {
            let severed = Array(snake[...hit])
            let severedHues = Array(segmentHues[...hit])
            snake.removeSubrange(...hit)
            segmentHues.removeSubrange(...hit)
            explode(severed, hues: severedHues)
            severanceCount += 1     // host watches this to fire the haptic
            // Self-cannibalism is no free trim: every destroyed segment costs
            // a point, and the score can go into the red.
            score -= severed.count
        }

        snake.append(head)
        if let i = foods.firstIndex(where: { $0.point == head }) {
            apply(foods.remove(at: i))
        }
    }

    /// Consume a pill: +1 score, countdown reset, plus the kind's burden.
    private func apply(_ eaten: Food) {
        // Eating anything expires an active red rush (bonus segments explode)
        // and lifts yellow's curse — both last exactly until the next eat.
        if redRush { expireRedRush() }
        fastDrain = false

        let before = unlockedKinds.count
        score += 1
        highWater = max(highWater, score)
        timeRemaining = GameModel.starveLimit
        // The body's fluid palette remembers the last five meals' shades.
        recentMeals.append(eaten.shade)
        if recentMeals.count > 5 { recentMeals.removeFirst() }
        switch eaten.kind {
        case .grow:
            pendingGrowth += 1
            pendingHues.append(eaten.shade)
        case .speed:
            speedFactor = min(speedFactor * 1.05, GameModel.maxSpeedFactor)
        case .scatter:
            pelletsRestless.toggle()
        case .time:
            fastDrain = true
        case .penalty:
            redRush = true
            pendingGrowth += GameModel.redRushSegments
            pendingHues.append(contentsOf: Array(repeating: eaten.kind.hue,
                                                 count: GameModel.redRushSegments))
            timeRemaining = GameModel.redCountdown   // the 5-second rule
        }

        // Crossing a milestone unlocks a new kind — announce it with a wave
        // in the newcomer's color from the center of the board.
        if unlockedKinds.count > before, let kind = unlockedKinds.last {
            announceUnlock(kind)
        }
        // Perfection: hitting the target ends the run on the spot, buying
        // the full 30-firework show.
        if score >= GameModel.winScore {
            beginFinale()
            return
        }

        // Shockwave + shard burst, both in the eaten pellet's own shade.
        ripples.append(Ripple(id: rippleCounter, center: eaten.point,
                              hue: eaten.shade, age: 0))
        rippleCounter += 1
        if FX.eatParticles {
            let cx = Double(eaten.point.x) + 0.5, cy = Double(eaten.point.y) + 0.5
            let n = GameModel.particleCount * GameModel.fxScale
            for k in 0..<n {
                let angle = (Double(k) / Double(n)) * 2 * .pi + Rand.d(-0.3...0.3)
                let speed = Rand.d(2.5...11)
                let size = Rand.d(0.10...0.22)
                particles.append(Particle(id: particleCounter, x: cx, y: cy,
                                          vx: cos(angle) * speed, vy: sin(angle) * speed,
                                          hue: eaten.shade + Rand.d(-0.03...0.03), age: 0,
                                          lifetime: shardLifetime(size: size, range: 0.10...0.22),
                                          size: size,
                                          angle: Rand.d(0...(2 * .pi)),
                                          spin: Rand.d(-5...5)))
                particleCounter += 1
            }
        }
        if FX.reactiveMood { eatFlash = 1 }
    }

    /// Blow up destroyed segments: a white shockwave from the break point plus
    /// a storm of shards, each cell bursting in that segment's own diet color.
    private func explode(_ cells: [Point], hues: [Double]) {
        guard let breakPoint = cells.last else { return }
        ripples.append(Ripple(id: rippleCounter, center: breakPoint, hue: -1, age: 0))
        rippleCounter += 1
        for (i, c) in cells.enumerated() {
            let cx = Double(c.x) + 0.5, cy = Double(c.y) + 0.5
            let hue = hues.indices.contains(i) ? hues[i] : 0
            for _ in 0..<(12 * GameModel.fxScale) {
                let angle = Rand.d(0...(2 * .pi))
                let speed = Rand.d(3...14)
                let size = Rand.d(0.08...0.20)
                particles.append(Particle(id: particleCounter, x: cx, y: cy,
                                          vx: cos(angle) * speed, vy: sin(angle) * speed,
                                          hue: hue + Rand.d(-0.05...0.05), age: 0,
                                          lifetime: shardLifetime(size: size, range: 0.08...0.20),
                                          size: size,
                                          angle: Rand.d(0...(2 * .pi)),
                                          spin: Rand.d(-12...12)))
                particleCounter += 1
            }
        }
    }

    /// The red rush ends: bonus segments still queued simply evaporate;
    /// materialized ones are marked for the staged pop in tick() — one every
    /// 0.05s, bursting at their (shuffled) current cells.
    private func expireRedRush() {
        redRush = false
        let redHue = FoodKind.penalty.hue
        let queued = pendingHues.filter { $0 == redHue }.count
        pendingGrowth -= queued
        pendingHues.removeAll { $0 == redHue }
        let cells = Rand.shuffled(zip(snake, segmentHues)
            .filter { $0.1 == redHue }.map { $0.0 })
        rushBurstCells.append(contentsOf: cells)
        rushPopsRemaining += cells.count
    }

    /// Cosmetic decay shared by normal play and the death sequence: trail,
    /// ripples, shards (with drag + body repulsion), and the eat-flash.
    private func ageEffects(_ dt: Double) {
        trail = trail.compactMap { mark in
            let aged = mark.age + dt
            return aged >= GameModel.trailLifetime
                ? nil
                : TrailMark(id: mark.id, point: mark.point, age: aged)
        }
        ripples = ripples.compactMap { r in
            let aged = r.age + dt
            return aged >= GameModel.rippleLifetime
                ? nil
                : Ripple(id: r.id, center: r.center, hue: r.hue, age: aged)
        }
        let drag = exp(-dt * GameModel.particleDrag)
        let repelR = GameModel.particleRepelRadius
        particles = particles.compactMap { p in
            var q = p
            q.age += dt
            guard q.age < q.lifetime else { return nil }
            var fx = 0.0, fy = 0.0
            for s in snake {
                let dx = q.x - (Double(s.x) + 0.5)
                let dy = q.y - (Double(s.y) + 0.5)
                let d2 = dx * dx + dy * dy
                guard d2 < repelR * repelR, d2 > 0.0001 else { continue }
                let d = d2.squareRoot()
                let f = GameModel.particleRepelForce * (1 - d / repelR) / max(d, 0.3)
                fx += dx * f
                fy += dy * f
            }
            q.vx = q.vx * drag + fx * dt
            q.vy = q.vy * drag + (fy + q.gravity) * dt
            q.x += q.vx * dt
            q.y += q.vy * dt
            q.angle += q.spin * dt
            return q
        }
        eatFlash = max(0, eatFlash - dt / GameModel.eatFlashDuration)
    }

    /// The run ends (clock out, or score target reached): the ribbon breaks
    /// into loose blocks that explode in random order (one per 0.05s), and a
    /// fireworks show is scheduled — one rocket per score point, positions
    /// spread over the whole screen's sky, ignitions randomized inside a
    /// window that grows with the show. Every ending is a win.
    private func beginFinale() {
        isDying = true
        won = true
        dyingTimer = 0
        dyingCells = zip(snake, segmentHues).map { ($0, $1) }
        snake = []
        prevSnake = []
        segmentHues = []
        foods = []          // the board goes dark; the sky takes over
        fireworks = []
        finaleClock = 0
        let n = FX.benchMaxFinale ? GameModel.winScore
                                  : max(0, min(score, GameModel.winScore))
        let t = n <= 1 ? 0.0 : Double(n - 1) / Double(GameModel.winScore - 1)
        finaleDuration = n == 0 ? 1.5
            : GameModel.finaleMinDuration
              + (GameModel.finaleMaxDuration - GameModel.finaleMinDuration) * t
        let window = GameModel.finaleMinWindow
            + (GameModel.finaleMaxWindow - GameModel.finaleMinWindow) * t
        guard FX.finaleFireworks else { return }
        let skyTop = 1 - GameModel.skyAbove
        let skyBottom = Double(GameModel.rows) + GameModel.skyBelow - 1.5
        // Round-robin through the five pellet color families so every show
        // spans the whole palette (pure random rolls can streak one color).
        let palette = Rand.shuffled(FoodKind.allCases)
        for i in 0..<n {
            fireworks.append(Firework(
                ignition: Rand.d(0...window),
                x: Rand.d(0.8...(Double(GameModel.cols) - 0.8)),
                y: Rand.d(skyTop...skyBottom),
                shade: palette[i % palette.count].randomShade()))
        }
    }

    /// A rocket bursts: a shell of falling, twinkling sparks in its shade.
    /// Spark lifetimes are cut to the show's remaining time so the last
    /// sparkle dies as the clock runs out.
    private func igniteFirework(_ f: Firework) {
        guard FX.eatParticles else { return }
        let remaining = max(1.2, finaleDuration - f.ignition)
        for _ in 0..<(Rand.i(50...80) * GameModel.fxScale) {
            let angle = Rand.d(0...(2 * .pi))
            let speed = Rand.d(2.5...8)
            particles.append(Particle(id: particleCounter, x: f.x, y: f.y,
                                      vx: cos(angle) * speed, vy: sin(angle) * speed,
                                      hue: f.shade + Rand.d(-0.05...0.05),
                                      age: 0,
                                      lifetime: Rand.d(0.45 * remaining...remaining),
                                      size: Rand.d(0.05...0.15),
                                      angle: Rand.d(0...(2 * .pi)),
                                      spin: Rand.d(-8...8),
                                      gravity: GameModel.sparkGravity,
                                      twinkle: true))
            particleCounter += 1
        }
    }

    /// A shard burst at `cell` around `hue`. The ranges default to the small
    /// everyday burst; callers can widen them for bigger spectacles.
    private func burst(at cell: Point, hue: Double, count: Int,
                       sizes: ClosedRange<Double> = 0.06...0.15,
                       hueSpread: Double = 0.04,
                       speeds: ClosedRange<Double> = 2...9) {
        guard FX.eatParticles else { return }
        let cx = Double(cell.x) + 0.5, cy = Double(cell.y) + 0.5
        for _ in 0..<(count * GameModel.fxScale) {
            let angle = Rand.d(0...(2 * .pi))
            let speed = Rand.d(speeds)
            let size = Rand.d(sizes)
            particles.append(Particle(id: particleCounter, x: cx, y: cy,
                                      vx: cos(angle) * speed, vy: sin(angle) * speed,
                                      hue: hue + Rand.d(-hueSpread...hueSpread), age: 0,
                                      lifetime: Rand.d(0.5...1.4),
                                      size: size,
                                      angle: Rand.d(0...(2 * .pi)),
                                      spin: Rand.d(-10...10)))
            particleCounter += 1
        }
    }

    /// A new pill kind just unlocked: a wave in its color sweeps the board.
    private func announceUnlock(_ kind: FoodKind) {
        let center = Point(x: GameModel.cols / 2, y: GameModel.rows / 2)
        ripples.append(Ripple(id: rippleCounter, center: center, hue: kind.hue, age: 0))
        rippleCounter += 1
        burst(at: center, hue: kind.hue, count: 16)
    }

    /// Cosmetic: spray sparks at an arbitrary cell-space position (may be
    /// off-board — the host uses this for D-pad press feedback below the
    /// grid). Pure data; the sparks join the normal shard simulation.
    func emitSparks(x: Double, y: Double, hue: Double, count: Int) {
        for _ in 0..<(count * GameModel.fxScale) {
            let angle = Rand.d(0...(2 * .pi))
            let speed = Rand.d(1.5...6)
            let size = Rand.d(0.05...0.13)
            particles.append(Particle(id: particleCounter, x: x, y: y,
                                      vx: cos(angle) * speed,
                                      vy: sin(angle) * speed - 2.5,   // drift up toward the board
                                      hue: hue + Rand.d(-0.04...0.04), age: 0,
                                      lifetime: Rand.d(0.6...1.6),
                                      size: size,
                                      angle: Rand.d(0...(2 * .pi)),
                                      spin: Rand.d(-8...8)))
            particleCounter += 1
        }
    }

    /// Lifetime for a shard of `size` within its spawn `range`: the larger the
    /// piece, the longer it lingers — small ones ~2s, the biggest up to 10s —
    /// with a little jitter so a burst doesn't fade in lockstep.
    private func shardLifetime(size: Double, range: ClosedRange<Double>) -> Double {
        let norm = (size - range.lowerBound) / (range.upperBound - range.lowerBound)
        let base = GameModel.particleLifeSmall
            + (GameModel.particleLifeLarge - GameModel.particleLifeSmall) * norm
        return min(GameModel.particleLifeLarge, base * Rand.d(0.85...1.15))
    }

    /// A random cell occupied by neither the snake nor another food.
    private func freeCell() -> Point? {
        var occupied = Set(snake.map { "\($0.x),\($0.y)" })
        for f in foods { occupied.insert("\(f.point.x),\(f.point.y)") }
        var free: [Point] = []
        for y in 0..<GameModel.rows {
            for x in 0..<GameModel.cols where !occupied.contains("\(x),\(y)") {
                free.append(Point(x: x, y: y))
            }
        }
        return Rand.pick(free)
    }

    private func spawnFood() {
        guard let pick = freeCell() else { return }
        // Kinds spawn from the unlocked set only — the board's variety (and
        // danger) grows with the score milestones. Duplicates are fine.
        guard let kind = Rand.pick(unlockedKinds) else { return }
        let shade = kind.randomShade()
        foods.append(Food(point: pick, kind: kind, shade: shade))
        spawnShimmer(at: pick, hue: shade)
    }

    /// The soft burst announcing a pellet appearing at `cell`.
    private func spawnShimmer(at cell: Point, hue: Double) {
        guard FX.eatParticles else { return }
        let cx = Double(cell.x) + 0.5, cy = Double(cell.y) + 0.5
        for _ in 0..<(14 * GameModel.fxScale) {
            let angle = Rand.d(0...(2 * .pi))
            let speed = Rand.d(1...4.5)
            let size = Rand.d(0.06...0.15)
            particles.append(Particle(id: particleCounter, x: cx, y: cy,
                                      vx: cos(angle) * speed, vy: sin(angle) * speed,
                                      hue: hue + Rand.d(-0.05...0.05), age: 0,
                                      lifetime: shardLifetime(size: size, range: 0.06...0.15),
                                      size: size,
                                      angle: Rand.d(0...(2 * .pi)),
                                      spin: Rand.d(-5...5)))
            particleCounter += 1
        }
    }

    /// The harder burst of a pellet whose fuse ran out.
    private func explodeFood(_ f: Food) {
        guard FX.eatParticles else { return }
        let cx = Double(f.point.x) + 0.5, cy = Double(f.point.y) + 0.5
        for _ in 0..<(18 * GameModel.fxScale) {
            let angle = Rand.d(0...(2 * .pi))
            let speed = Rand.d(2...8)
            let size = Rand.d(0.07...0.17)
            particles.append(Particle(id: particleCounter, x: cx, y: cy,
                                      vx: cos(angle) * speed, vy: sin(angle) * speed,
                                      hue: f.shade + Rand.d(-0.03...0.03), age: 0,
                                      lifetime: Rand.d(0.6...1.6),
                                      size: size,
                                      angle: Rand.d(0...(2 * .pi)),
                                      spin: Rand.d(-8...8)))
            particleCounter += 1
        }
    }
}

// MARK: - Draw-list (the portable seam)

/// Shape selector baked into each instance; matched by the fragment shader.
enum ShapeID: Float {
    case rect   = 0   // rounded/solid rectangle (corner radius in `b.z`)
    case circle = 1   // filled disc (radius = halfShape.x)
    case ring   = 2   // hollow ring (radius = halfShape.x, thickness = misc.z)
    case glyph  = 3   // textured glyph from the atlas (uv in `uv`)
    case bg     = 4   // fullscreen diagonal 3-stop gradient
    case frame  = 5   // rounded-rect stroke (corner = b.z, thickness = misc.z)
}

/// One GPU instance. Packed entirely into float4s so the Swift and MSL structs
/// share an unambiguous, padding-free 96-byte layout.
struct GPUInstance {
    var a:     SIMD4<Float>   // center.xy, halfQuad.xy   (halfQuad includes glow margin)
    var b:     SIMD4<Float>   // halfShape.xy, corner(z), shapeID(w)
    var color: SIMD4<Float>   // fill rgba                 (bg: stop A.rgb)
    var glow:  SIMD4<Float>   // glow.rgb, glowStrength    (bg: stop B.rgb)
    var uv:    SIMD4<Float>   // glyph atlas: origin.xy, size.zw  (bg: stop C.rgb)
    var misc:  SIMD4<Float>   // edgeSoftness(x), glowRadius(y), strokeThk(z), rotation(w)
}

/// Accumulates primitives for one frame. Pure data — knows nothing about Metal.
struct DrawList {
    var instances: [GPUInstance] = []

    mutating func add(_ shape: ShapeID,
                      center: SIMD2<Float>, halfShape: SIMD2<Float>,
                      corner: Float = 0,
                      color: SIMD4<Float>,
                      glowColor: SIMD3<Float> = .zero, glowStrength: Float = 0,
                      glowRadius: Float = 0, soft: Float = 1, strokeThk: Float = 0,
                      rot: Float = 0) {
        let margin = glowRadius * 3 + soft + 1     // room for the halo so it isn't clipped
        // A rotated shape needs a quad that covers its bounding circle.
        let bound = rot == 0 ? halfShape : SIMD2(repeating: length(halfShape))
        let halfQuad = bound + SIMD2(margin, margin)
        instances.append(GPUInstance(
            a: SIMD4(center.x, center.y, halfQuad.x, halfQuad.y),
            b: SIMD4(halfShape.x, halfShape.y, corner, shape.rawValue),
            color: color,
            glow: SIMD4(glowColor.x, glowColor.y, glowColor.z, glowStrength),
            uv: .zero,
            misc: SIMD4(soft, glowRadius, strokeThk, rot)))
    }

    /// Fullscreen background gradient (three diagonal stops, already hue-rotated).
    mutating func addBackground(viewSize: SIMD2<Float>,
                                a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let half = viewSize * 0.5
        instances.append(GPUInstance(
            a: SIMD4(half.x, half.y, half.x, half.y),
            b: SIMD4(half.x, half.y, 0, ShapeID.bg.rawValue),
            color: SIMD4(a.x, a.y, a.z, 1),
            glow: SIMD4(b.x, b.y, b.z, 1),
            uv: SIMD4(c.x, c.y, c.z, 1),
            misc: .zero))
    }

    /// One textured glyph quad sampled from the atlas.
    mutating func addGlyph(center: SIMD2<Float>, size: SIMD2<Float>,
                           uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>,
                           color: SIMD4<Float>) {
        let half = size * 0.5
        instances.append(GPUInstance(
            a: SIMD4(center.x, center.y, half.x, half.y),
            b: SIMD4(half.x, half.y, 0, ShapeID.glyph.rawValue),
            color: color,
            glow: .zero,
            uv: SIMD4(uvOrigin.x, uvOrigin.y, uvSize.x, uvSize.y),
            misc: .zero))
    }
}

// MARK: - Color helpers

func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> SIMD4<Float> {
    SIMD4(Float(r), Float(g), Float(b), Float(a))
}

/// HSV → RGB (h, s, v in 0...1). Mirrors SwiftUI's `Color(hue:saturation:brightness:)`.
func hsv2rgb(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Float> {
    let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
    let i = Int(hh)
    let f = hh - Double(i)
    let p = v * (1 - s)
    let q = v * (1 - s * f)
    let t = v * (1 - s * (1 - f))
    let (r, g, b): (Double, Double, Double)
    switch i % 6 {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default:(r, g, b) = (v, p, q)
    }
    return SIMD3(Float(r), Float(g), Float(b))
}

func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

// MARK: - Glyph atlas (HUD text, rendered through the same pipeline)

/// A bitmap font atlas: every needed glyph baked into one texture once at
/// startup. Building the atlas is platform tooling (UIKit text rasterization);
/// the per-glyph quad emission below is plain arithmetic and ports as-is.
final class GlyphAtlas {
    struct Glyph {
        let uvOrigin: SIMD2<Float>
        let uvSize: SIMD2<Float>
        let advance: Float     // slot width in atlas pixels
    }

    let texture: MTLTexture
    let lineHeight: Float
    private var glyphs: [Character: Glyph] = [:]

    init?(device: MTLDevice) {
        // Every character any HUD string can contain.
        let chars = Array(Set("Score: Time: 0123456789.-/Game OverTap to restartYou Win!dash"))
        let font = UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        let lh = ceil(font.lineHeight)

        // Measure each glyph and lay them out left-to-right in a single row.
        let pad: CGFloat = 4
        var widths: [Character: CGFloat] = [:]
        var totalW: CGFloat = 0
        for ch in chars {
            let w = ceil((String(ch) as NSString)
                .size(withAttributes: [.font: font]).width) + pad
            widths[ch] = w
            totalW += w
        }

        let atlasW = max(1, Int(totalW))
        let atlasH = max(1, Int(lh))

        // Rasterize into a known RGBA8 buffer and upload the bytes directly.
        // (MTKTextureLoader rejects UIGraphicsImageRenderer's premultiplied
        // CGImage with "Image decoding failed", so we skip it entirely.)
        let bytesPerRow = atlasW * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * atlasH)
        guard let ctx = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: atlasW, height: atlasH,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else {
            print("GlyphAtlas: CGContext create failed"); return nil
        }
        // Flip to UIKit's top-left origin so text isn't drawn upside down.
        ctx.translateBy(x: 0, y: CGFloat(atlasH))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        var drawX: CGFloat = 0
        for ch in chars {
            let w = widths[ch] ?? 0
            (String(ch) as NSString).draw(
                at: CGPoint(x: drawX, y: 0),
                withAttributes: [.font: font, .foregroundColor: UIColor.white])
            drawX += w
        }
        UIGraphicsPopContext()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: atlasW, height: atlasH, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else {
            print("GlyphAtlas: makeTexture failed"); return nil
        }
        tex.replace(region: MTLRegionMake2D(0, 0, atlasW, atlasH), mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: bytesPerRow)

        self.texture = tex
        self.lineHeight = Float(lh)

        // Record each glyph's UV slot now that we know the final atlas width.
        var penX: CGFloat = 0
        let fw = CGFloat(atlasW), fh = CGFloat(atlasH)
        for ch in chars {
            let w = widths[ch] ?? 0
            glyphs[ch] = Glyph(
                uvOrigin: SIMD2(Float(penX / fw), 0),
                uvSize: SIMD2(Float(w / fw), Float(lh / fh)),
                advance: Float(w))
            penX += w
        }
    }

    /// Width in points of `string` rendered at the given pixel height.
    func width(_ string: String, pixelHeight: Float) -> Float {
        let scale = pixelHeight / lineHeight
        return string.reduce(Float(0)) { $0 + (glyphs[$1]?.advance ?? 0) * scale }
    }

    /// Emit one glyph quad per character into `list`, left-aligned at `topLeft`.
    func append(_ string: String, into list: inout DrawList,
                topLeft: SIMD2<Float>, pixelHeight: Float, color: SIMD4<Float>) {
        let scale = pixelHeight / lineHeight
        var penX = topLeft.x
        for ch in string {
            guard let g = glyphs[ch] else { continue }
            let w = g.advance * scale
            if ch != " " {
                list.addGlyph(
                    center: SIMD2(penX + w * 0.5, topLeft.y + pixelHeight * 0.5),
                    size: SIMD2(w, pixelHeight),
                    uvOrigin: g.uvOrigin, uvSize: g.uvSize, color: color)
            }
            penX += w
        }
    }

    /// Convenience: centered text about `centerX`.
    func appendCentered(_ string: String, into list: inout DrawList,
                        centerX: Float, top: Float, pixelHeight: Float,
                        color: SIMD4<Float>) {
        let w = width(string, pixelHeight: pixelHeight)
        append(string, into: &list,
               topLeft: SIMD2(centerX - w * 0.5, top),
               pixelHeight: pixelHeight, color: color)
    }
}

// MARK: - Scene builder (model state → draw-list)

/// Pixel geometry of the play area within the view, computed each frame.
struct Layout {
    var viewSize: SIMD2<Float>
    var cell: Float
    /// Reference size for HUD text so it stays put when `cell` is enlarged.
    /// (Everything gameplay-related scales with `cell`; text scales with this.)
    var textUnit: Float
    var boardX: Float       // top-left of the board
    var boardY: Float
    var boardW: Float
    var boardH: Float

    /// Center of grid cell (x, y) in view pixels.
    func cellCenter(_ x: Double, _ y: Double) -> SIMD2<Float> {
        SIMD2(boardX + Float(x + 0.5) * cell, boardY + Float(y + 0.5) * cell)
    }
}

/// Builds the full frame's draw-list from the model and a few animation phases.
/// No Metal, no UIKit — just data in, primitives out.
struct SceneBuilder {
    let atlas: GlyphAtlas

    func build(game: GameModel, layout: Layout,
               hueShift: Double, foodPulse: Float, headPulse: Float,
               dashTint: Float, pathPhase: Float, fluidPhase: Double,
               scoreScale: Float, emberTime: Double) -> DrawList {
        var list = DrawList()
        let cell = layout.cell

        // --- Ambient embers: a stateless full-screen dust field ---------------
        // Positions are a pure function of time and index (golden-ratio
        // scatter + per-mote drift/sway/pulse) — no model state, no aging.
        // Computed up front so the grid-light pass below can reuse them.
        var embers: [(pos: SIMD2<Float>, rgb: SIMD3<Float>, alpha: Float, size: Float)] = []
        if FX.ambientEmbers {
            let top = -GameModel.skyAbove
            let span = Double(GameModel.rows) + GameModel.skyBelow - top
            for i in 0..<(40 * GameModel.fxScale) {
                let fi = Double(i)
                let fx = (fi * 0.6180339887).truncatingRemainder(dividingBy: 1)
                let fy = (fi * 0.3819660113).truncatingRemainder(dividingBy: 1)
                let fz = (fi * 0.7548776662).truncatingRemainder(dividingBy: 1)
                let phase = fi * 2.399963
                let speed = 0.15 + 0.35 * fz
                var y = (fy * span - emberTime * speed)
                    .truncatingRemainder(dividingBy: span)
                if y < 0 { y += span }
                y += top
                let x = fx * Double(GameModel.cols + 2) - 1
                    + 0.6 * sin(emberTime * (0.3 + 0.2 * fx) + phase)
                let pulse = 0.5 + 0.5 * sin(emberTime * (0.8 + fx) + phase * 1.7)
                embers.append((layout.cellCenter(x, y),
                               hsv2rgb(0.42 + 0.13 * fz, 0.6, 1.0),
                               Float(0.10 + 0.16 * pulse),
                               cell * Float(0.04 + 0.05 * fy)))
            }
        }

        // --- Background (#1, #5) ---------------------------------------------
        if FX.animatedBackground {
            let scoreHue = FX.reactiveMood ? Double(game.score) * 14.0 / 360.0 : 0
            let h = hueShift + scoreHue
            // Three dim base stops, hue-rotated together over time + score.
            let a = rotatedStop(0.10, 0.02, 0.20, by: h)
            let b = rotatedStop(0.20, 0.03, 0.30, by: h)
            let c = rotatedStop(0.02, 0.10, 0.22, by: h)
            list.addBackground(viewSize: layout.viewSize, a: a, b: b, c: c)
        } else {
            list.addBackground(viewSize: layout.viewSize,
                               a: .zero, b: .zero, c: .zero)
        }

        // --- Board surface ---------------------------------------------------
        let boardCenter = SIMD2(layout.boardX + layout.boardW * 0.5,
                                layout.boardY + layout.boardH * 0.5)
        list.add(.rect, center: boardCenter,
                 halfShape: SIMD2(layout.boardW * 0.5, layout.boardH * 0.5),
                 corner: cell * 0.6,
                 color: FX.animatedBackground ? rgba(0, 0, 0, 0.45) : rgba(0.12, 0.12, 0.12))

        // Embers drift over the board surface but under everything else.
        for e in embers {
            list.add(.circle, center: e.pos, halfShape: SIMD2(e.size, e.size),
                     color: SIMD4(e.rgb.x, e.rgb.y, e.rgb.z, e.alpha),
                     glowColor: e.rgb, glowStrength: e.alpha * 0.8,
                     glowRadius: e.size * 2)
        }

        // --- Snake ribbon path --------------------------------------------------
        // The body slides at constant speed along the polyline of cells it
        // occupies (plus the cell the tail is vacating). Beads sampled along
        // that path — with a light 1-2-1 smoothing of the parameter — render
        // corners as rounded bends instead of right-angle snaps. The chain is
        // built in *unwrapped* coordinates (each link a unit step, even across
        // a board edge); positions wrap back onto the board only when drawn.
        let count = game.snake.count
        // Constant speed with a whisper of ease-in-out (35% smoothstep blend) —
        // just enough breath per cell to not feel mechanical, without the
        // stutter a full per-cell ease produces at this step rate.
        let t = game.moveProgress
        let hop = t + 0.35 * (t * t * (3 - 2 * t) - t)
        let colsD = Double(GameModel.cols), rowsD = Double(GameModel.rows)

        var chainCells: [Point] = []
        if game.prevSnake.count == count, let oldTail = game.prevSnake.first,
           oldTail != game.snake.first {
            chainCells.append(oldTail)      // tail is mid-slide out of this cell
        }
        chainCells.append(contentsOf: game.snake)
        // (During the death sequence the snake is empty — the ribbon math
        // degenerates safely and the body renders as dyingCells blocks below.)
        var chain: [SIMD2<Double>] = [chainCells.first.map {
            SIMD2(Double($0.x), Double($0.y)) } ?? SIMD2(0, 0)]
        for k in 1..<max(1, chainCells.count) {
            var dx = Double(chainCells[k].x - chainCells[k - 1].x)
            var dy = Double(chainCells[k].y - chainCells[k - 1].y)
            if dx > 1 { dx -= colsD }; if dx < -1 { dx += colsD }
            if dy > 1 { dy -= rowsD }; if dy < -1 { dy += rowsD }
            chain.append(chain[k - 1] + SIMD2(dx, dy))
        }
        let totalArc = Double(chain.count - 1)
        // Head eases toward the chain's end over the move interval; the body
        // trails it at unit spacing (tail clamps while growing).
        let headMoved = game.prevSnake.last != game.snake.last
        let sHead = headMoved ? totalArc - (1 - hop) : totalArc
        let sTail = max(0, sHead - Double(count - 1))

        func chainPoint(_ s: Double) -> SIMD2<Double> {
            guard chain.count > 1 else { return chain[0] }
            let sc = min(max(s, 0), totalArc)
            let i = min(Int(sc), chain.count - 2)
            return chain[i] + (chain[i + 1] - chain[i]) * (sc - Double(i))
        }
        /// Corner-rounded path point: small 1-2-1 blur along the parameter.
        /// Straight runs are unaffected; 90° corners become smooth arcs.
        func ribbonPoint(_ s: Double) -> SIMD2<Double> {
            (chainPoint(s - 0.35) + chainPoint(s) * 2 + chainPoint(s + 0.35)) * 0.25
        }
        /// Wrap an unwrapped cell-space point back onto the board. Board cells
        /// span [-0.5, n-0.5) in this space (0 = center of the first cell).
        func wrapPoint(_ p: SIMD2<Double>) -> SIMD2<Double> {
            func wrap1(_ v: Double, _ n: Double) -> Double {
                ((v + 0.5).truncatingRemainder(dividingBy: n) + n)
                    .truncatingRemainder(dividingBy: n) - 0.5
            }
            return SIMD2(wrap1(p.x, colsD), wrap1(p.y, rowsD))
        }
        /// Draw positions for a bead: its wrapped position, plus a twin on the
        /// opposite edge while the bead is partway off the board mid-wrap.
        func beadPositions(_ p: SIMD2<Double>) -> [SIMD2<Double>] {
            let w = wrapPoint(p)
            var xs = [w.x], ys = [w.y]
            if w.x < 0 { xs.append(w.x + colsD) } else if w.x > colsD - 1 { xs.append(w.x - colsD) }
            if w.y < 0 { ys.append(w.y + rowsD) } else if w.y > rowsD - 1 { ys.append(w.y - rowsD) }
            var out: [SIMD2<Double>] = []
            for x in xs { for y in ys { out.append(SIMD2(x, y)) } }
            return out
        }

        // --- Light sources for the grid ---------------------------------------
        // The grid idles almost invisible; anything colorful nearby — snake
        // segments, food pellets, confetti — lights up the lines around it in
        // its own color. Each light: position (px), color, reach, strength.
        // Segment colors computed once, shared by the grid lighting and the
        // snake rendering below so the two always agree. The body is a
        // lava-lamp fluid mixing the last five meals' shades: colored blobs
        // drift along the body (flow speed follows the snake's speed) with
        // wobbling boundaries. Yellow's curse / a red rush paint the whole
        // body solid in that status color until the next eat.
        var palette = game.recentMeals
        while palette.count < 5 { palette.insert(GameModel.baseSegmentHue, at: 0) }
        let statusHue: Double? = game.redRush ? FoodKind.penalty.hue
                               : (game.fastDrain ? FoodKind.time.hue : nil)
        func fluidColor(_ f: Double, isHead: Bool) -> SIMD3<Float> {
            let v = isHead ? 1.0 : 0.88
            if let s = statusHue {
                return hsv2rgb(s, 0.92, v * (0.72 + 0.28 * Double(headPulse)))
            }
            // Two palette cycles along the body, drifting with fluidPhase and
            // warped by a slow sine so the blobs swell and squeeze.
            let u = f * 2.0 + fluidPhase + 0.25 * sin(f * 9.0 + fluidPhase * 1.7)
            let x = ((u.truncatingRemainder(dividingBy: 1) + 1)
                        .truncatingRemainder(dividingBy: 1)) * 5
            let i = min(Int(x), 4)
            let t = x - Double(i)
            let tt = t * t * (3 - 2 * t)
            return mix3(hsv2rgb(palette[i], 0.85, v),
                        hsv2rgb(palette[(i + 1) % 5], 0.85, v), Float(tt))
        }
        var snakeColors: [SIMD3<Float>] = []
        snakeColors.reserveCapacity(count)
        for idx in 0..<count {
            let isHead = idx == count - 1
            let f = count > 1 ? Double(idx) / Double(count - 1) : 1
            let base = fluidColor(f, isHead: isHead)
            let yellow: SIMD3<Float> = isHead ? SIMD3(1.0, 0.9, 0.25) : SIMD3(0.95, 0.8, 0.15)
            snakeColors.append(mix3(base, yellow, dashTint))
        }
        var lights: [(pos: SIMD2<Float>, rgb: SIMD3<Float>, radius: Float, strength: Float)] = []
        for idx in 0..<count {
            let isHead = idx == count - 1
            let s = max(sTail, sHead - Double(count - 1 - idx))
            let pos = wrapPoint(ribbonPoint(s))
            lights.append((layout.cellCenter(pos.x, pos.y), snakeColors[idx],
                           cell * (isHead ? 2.2 : 1.6), isHead ? 1.0 : 0.6))
        }
        for c in game.dyingCells {
            lights.append((layout.cellCenter(Double(c.point.x), Double(c.point.y)),
                           hsv2rgb(c.hue, 0.8, 1.0), cell * 1.6, 0.7))
        }
        for f in game.foods {
            lights.append((layout.cellCenter(Double(f.point.x), Double(f.point.y)),
                           hsv2rgb(f.shade, 0.95, 1.0), cell * 2.4, 0.8 + 0.4 * foodPulse))
        }
        if FX.eatParticles {
            for part in game.particles {
                // Shards light the grid only while fresh (~2s); the long ember
                // fade shouldn't keep the whole board glowing for 10 seconds.
                let fresh = Float(max(0, 1 - part.age / 2))
                guard fresh > 0.02 else { continue }
                lights.append((layout.cellCenter(part.x - 0.5, part.y - 0.5),
                               hsv2rgb(part.hue, 0.9, 1.0), cell * 1.1, 0.7 * fresh))
            }
        }
        // Experimental (FX.emberLights): every dust mote is a permanent dim
        // light — flip the flag to fully revert to non-lighting embers.
        if FX.ambientEmbers && FX.emberLights {
            for e in embers {
                lights.append((e.pos, e.rgb, cell * 0.9, 0.45 * e.alpha))
            }
        }

        // --- Eat-ripple wavefronts --------------------------------------------
        // Each active ripple is a wavefront (center px, front radius, strength)
        // shared by the grid distortion here and the ring rendering below.
        let waves: [(center: SIMD2<Float>, radius: Float, strength: Float, rgb: SIMD3<Float>)] =
            game.ripples.map { r in
                let prog = Float(r.age / GameModel.rippleLifetime)
                return (layout.cellCenter(Double(r.center.x), Double(r.center.y)),
                        cell * (0.5 + Float(GameModel.rippleTravel) * prog),
                        1 - prog,
                        r.hue >= 0 ? hsv2rgb(r.hue, 0.75, 1.0) : SIMD3<Float>(1, 1, 1))
            }
        /// Displacement, brightness boost, and summed light color the
        /// wavefronts impart at `p` (each wave glows in its food's color).
        func waveEffect(at p: SIMD2<Float>) -> (offset: SIMD2<Float>, boost: Float, rgb: SIMD3<Float>) {
            var offset = SIMD2<Float>(0, 0)
            var boost: Float = 0
            var rgb = SIMD3<Float>(0, 0, 0)
            for w in waves {
                let d = p - w.center
                let dist = max(length(d), 0.001)
                let x = (dist - w.radius) / (cell * 0.9)   // wavefront thickness
                guard abs(x) < 3 else { continue }
                let g = exp(-x * x)
                offset += (d / dist) * (cell * 0.35 * w.strength * g)
                boost += w.strength * g
                rgb += w.rgb * (w.strength * g)
            }
            return (offset, boost, rgb)
        }

        // --- Neon grid lines (#3) --------------------------------------------
        if FX.neonGrid {
            // Lines are drawn as per-cell segments so effects can act on them
            // locally: a wavefront bends and brightens them (in the food's
            // color), and nearby lights tint them. Unlit segments are not
            // drawn at all — the grid only exists where something lights it.
            func addGridSegment(at center: SIMD2<Float>, halfShape: SIMD2<Float>) {
                let (off, boost, waveRGB) = waveEffect(at: center)
                var w = boost                       // wave light, in its own color
                var acc = waveRGB
                for l in lights {
                    let d2 = length_squared(center - l.pos)
                    let r2 = l.radius * l.radius
                    guard d2 < r2 * 9 else { continue }
                    let f = exp(-d2 / r2) * l.strength
                    w += f
                    acc += l.rgb * f
                }
                // No drawn board border: light fades out toward the edge over
                // the outermost cell, so the grid just dissolves at the rim.
                let edgeDist = min(min(center.x - layout.boardX,
                                       layout.boardX + layout.boardW - center.x),
                                   min(center.y - layout.boardY,
                                       layout.boardY + layout.boardH - center.y))
                let intensity = min(1, w) * min(1, edgeDist / cell + 0.25)
                guard intensity > 0.02 else { return }
                let rgb = mix3(SIMD3(0, 1, 1), acc / w, intensity)
                list.add(.rect, center: center + off, halfShape: halfShape,
                         color: SIMD4(rgb.x, rgb.y, rgb.z, 0.65 * intensity),
                         glowColor: rgb, glowStrength: 0.9 * intensity,
                         glowRadius: 1.5 + 4 * intensity)
            }
            // Vertical segments tile the line exactly; horizontal ones stop
            // short of the verticals so a crossing is never drawn twice (the
            // double-blended intersections read as distracting bright dots).
            let vHalf = cell * 0.5
            let hHalf = cell * 0.5 - 1.5
            for i in 0...GameModel.cols {
                let x = layout.boardX + Float(i) * cell
                for j in 0..<GameModel.rows {
                    addGridSegment(at: SIMD2(x, layout.boardY + (Float(j) + 0.5) * cell),
                                   halfShape: SIMD2(0.5, vHalf))
                }
            }
            for j in 0...GameModel.rows {
                let y = layout.boardY + Float(j) * cell
                for i in 0..<GameModel.cols {
                    addGridSegment(at: SIMD2(layout.boardX + (Float(i) + 0.5) * cell, y),
                                   halfShape: SIMD2(hHalf, 0.5))
                }
            }
        }

        // --- Path preview: animated glow along the cells the snake will cross -
        if let dest = game.destination, let head = game.snake.last, head != dest {
            let path = previewPath(from: head, to: dest)
            for (i, p) in path.enumerated() {
                // A pulse that travels from the snake toward the destination.
                let wave = 0.5 + 0.5 * sin((Float(i) * 0.35 - pathPhase) * 2 * .pi)
                let half = cell * 0.32
                list.add(.rect, center: layout.cellCenter(Double(p.x), Double(p.y)),
                         halfShape: SIMD2(half, half), corner: cell * 0.3,
                         color: rgba(0.35, 0.85, 1.0, Double(0.12 + 0.30 * wave)),
                         glowColor: SIMD3(0.3, 0.85, 1.0),
                         glowStrength: 0.25 + 0.5 * wave, glowRadius: cell * 0.28)
            }
        }

        // --- Foods: pulsing orbs, one color per kind ---------------------------
        // neon yellow = grow, cyan = speed, purple = time, hot pink = red pill.
        let foodScale = 0.9 + 0.22 * foodPulse                 // 0.9 → 1.12
        let foodHalf = cell * 0.45 * foodScale
        let foodGlowR = cell * (0.3 + 0.7 * foodPulse)
        for f in game.foods {
            let rgb = hsv2rgb(f.shade, 0.95, 1.0)
            // Past the warn mark the pellet blips — fast hard glow flashes,
            // whitening core, slight swell — telegraphing the 5s fuse.
            let blink: Float = f.age > GameModel.foodWarnTime
                ? 0.5 + 0.5 * Float(sin(f.age * 2 * .pi * 4)) : 0
            let core = mix3(rgb, SIMD3(1, 1, 1), 0.45 * blink)
            let half = foodHalf * (1 + 0.12 * blink)
            list.add(.circle,
                     center: layout.cellCenter(Double(f.point.x), Double(f.point.y)),
                     halfShape: SIMD2(half, half),
                     color: SIMD4(core.x, core.y, core.z, 1),
                     glowColor: rgb, glowStrength: 0.9 + 0.7 * blink,
                     glowRadius: foodGlowR * (1 + 0.5 * blink))
        }

        // --- Destination marker: pulsing cyan ring on the player's target ----
        if let dest = game.destination {
            let pulse = 0.5 + 0.5 * foodPulse
            let radius = cell * (0.5 + 0.2 * pulse)
            list.add(.ring, center: layout.cellCenter(Double(dest.x), Double(dest.y)),
                     halfShape: SIMD2(radius, radius),
                     color: rgba(0.5, 0.95, 1.0, 0.9),
                     glowColor: SIMD3(0.3, 0.9, 1.0), glowStrength: 0.5,
                     glowRadius: cell * 0.3, strokeThk: max(1, cell * 0.12))
        }

        // --- Tail wake trail -------------------------------------------------
        for mark in game.trail {
            let life = Float(max(0, 1 - mark.age / GameModel.trailLifetime))
            let boost = 1 + Float(game.dashGlow)
            let half = (cell - 1) * 0.5 * life
            guard half > 0.5 else { continue }
            list.add(.rect, center: layout.cellCenter(Double(mark.point.x), Double(mark.point.y)),
                     halfShape: SIMD2(half, half), corner: cell * 0.2,
                     color: rgba(0.7, 1.0, 0.75, Double(min(1, 0.5 * life * boost))),
                     glowColor: SIMD3(0.3, 1, 0.45),
                     glowStrength: min(1, 0.6 * life * boost),
                     glowRadius: cell * 0.5 * life * boost)
        }

        // --- Snake ribbon ------------------------------------------------------
        // Closely spaced beads along the smoothed path — overlapping rounded
        // squares oriented to the local tangent, so the body reads as one
        // continuous ribbon that bends around corners. Tail drawn first so the
        // head lands on top. Colors interpolate along `snakeColors` (shared
        // with the grid lighting).
        // Death sequence: the ribbon has broken into loose blocks, each
        // holding its diet color until its turn to explode.
        for c in game.dyingCells {
            let rgb = hsv2rgb(c.hue, 0.8, 0.9)
            let half = (cell - 1) * 0.5
            list.add(.rect, center: layout.cellCenter(Double(c.point.x), Double(c.point.y)),
                     halfShape: SIMD2(half, half), corner: cell * 0.2,
                     color: SIMD4(rgb.x, rgb.y, rgb.z, 1),
                     glowColor: rgb, glowStrength: 0.7, glowRadius: cell * 0.3)
        }

        let dashBoost = 1 + Float(game.dashGlow)
        let bodySpan = sHead - sTail
        let beadCount = max(1, Int((bodySpan * 3).rounded()))   // ~3 beads/cell
        for k in 0..<(count > 0 ? beadCount + 1 : 0) {
            let f = Double(k) / Double(beadCount)               // 0 tail → 1 head
            let s = sTail + bodySpan * f
            let p = ribbonPoint(s)
            let tangent = chainPoint(s + 0.2) - chainPoint(s - 0.2)
            let rot = Float(atan2(tangent.y, tangent.x))
            let isHead = k == beadCount

            let fi = f * Double(count - 1)
            let i0 = min(Int(fi), count - 1)
            let core = mix3(snakeColors[i0], snakeColors[min(i0 + 1, count - 1)],
                            Float(fi - Double(i0)))

            let glowScale: Float = (isHead && game.dashReady) ? (1 + headPulse) : 1
            let baseOpacity: Float = isHead ? 0.95 : 0.55
            let half = (cell - 1) * 0.5
            let glowR = (isHead ? cell * 0.5 : cell * 0.25) * glowScale * dashBoost
            for pos in beadPositions(p) {
                list.add(.rect, center: layout.cellCenter(pos.x, pos.y),
                         halfShape: SIMD2(half, half), corner: cell * 0.2,
                         color: SIMD4(core.x, core.y, core.z, 1),
                         glowColor: core,
                         glowStrength: baseOpacity + (1 - baseOpacity) * Float(game.dashGlow),
                         glowRadius: glowR, rot: rot)
            }
        }

        // --- Eat-ripples: expanding rings riding the wavefronts --------------
        for (w, r) in zip(waves, game.ripples) {
            let prog = Float(r.age / GameModel.rippleLifetime)        // 0 → 1
            let fade = w.strength * w.strength     // ease out as it travels
            let thk = max(0.5, cell * 0.16 * (1 - 0.6 * prog))
            // Each ring glows in the color of the food that spawned it
            // (white-hot for severance shockwaves).
            list.add(.ring, center: w.center,
                     halfShape: SIMD2(w.radius, w.radius),
                     color: SIMD4(w.rgb.x, w.rgb.y, w.rgb.z, fade * 0.9),
                     glowColor: w.rgb, glowStrength: 0.5 * fade,
                     glowRadius: cell * 0.4, strokeThk: thk)
        }

        // --- Food shards (#4) -------------------------------------------------
        // Rounded-square shards — the same shape family as the cells and food —
        // tumbling gently and shrinking as they fade.
        if FX.eatParticles {
            for part in game.particles {
                let life = Float(max(0, 1 - part.age / part.lifetime))
                // Firework sparks flicker hard through their last stretch.
                var flicker: Float = 1
                if part.twinkle && life < 0.45 {
                    flicker = 0.3 + 0.7 * Float(0.5 + 0.5 * sin(part.age * 26
                                                + Double(part.id) * 2.7))
                }
                let base = cell * Float(part.size) * (0.4 + 0.6 * life) + 1
                let rgb = hsv2rgb(part.hue, 0.85, 1.0)
                list.add(.rect, center: layout.cellCenter(part.x - 0.5, part.y - 0.5),
                         halfShape: SIMD2(base, base * 0.72), corner: base * 0.3,
                         color: SIMD4(rgb.x, rgb.y, rgb.z, life * flicker),
                         glowColor: rgb, glowStrength: life * flicker,
                         glowRadius: cell * 0.2 * life, rot: Float(part.angle))
            }
        }

        // --- Finale fireworks: rising streaks and burst rings ------------------
        // Sparks are ordinary particles above; here we add each rocket's
        // 0.35s rising streak and the expanding ring flash at its burst.
        if FX.finaleFireworks && game.isDying {
            for fw in game.fireworks {
                let dtIgnite = game.finaleClock - fw.ignition
                if dtIgnite < 0 && dtIgnite > -GameModel.streakDuration {
                    let t = 1 + dtIgnite / GameModel.streakDuration     // 0 → 1
                    let y0 = fw.y + 3.0
                    let y = y0 + (fw.y - y0) * t
                    let rgb = hsv2rgb(fw.shade, 0.55, 1.0)
                    list.add(.rect,
                             center: layout.cellCenter(fw.x - 0.5, y - 0.5),
                             halfShape: SIMD2(cell * 0.05, cell * 0.35),
                             corner: cell * 0.05,
                             color: SIMD4(rgb.x, rgb.y, rgb.z, 0.9),
                             glowColor: rgb, glowStrength: 0.8,
                             glowRadius: cell * 0.3)
                } else if dtIgnite >= 0 && dtIgnite < 0.6 {
                    let a = Float(dtIgnite / 0.6)
                    let rgb = hsv2rgb(fw.shade, 0.8, 1.0)
                    let radius = cell * (0.4 + 5.5 * a)
                    list.add(.ring,
                             center: layout.cellCenter(fw.x - 0.5, fw.y - 0.5),
                             halfShape: SIMD2(radius, radius),
                             color: SIMD4(rgb.x, rgb.y, rgb.z, (1 - a) * 0.9),
                             glowColor: rgb, glowStrength: 1 - a,
                             glowRadius: cell * 0.5,
                             strokeThk: cell * 0.06 * (1 - a) + 1)
                }
            }
        }

        // (No board frame: the play area has no drawn border — grid light just
        // fades out over the outermost cell, see edgeFade in addGridSegment.)

        // --- HUD text (sized via textUnit so it doesn't grow with the cells) --
        let cx = layout.viewSize.x * 0.5
        let tu = layout.textUnit
        // HUD: bare countdown number top-left, bare score top-right (the
        // score zooms in and out for half a second whenever a point lands).
        let hudTop = layout.boardY - tu * 1.5
        // Countdown (left): glows purple under the time curse, red when low.
        let danger = game.timeRemaining <= 3
        let timeText = String(format: "%.1f", game.timeRemaining)
        let timeLeft = tu * 1.2
        let timeW = atlas.width(timeText, pixelHeight: tu * 1.0)
        if game.fastDrain || danger {
            let glowRGB: SIMD3<Float> = danger ? SIMD3(1, 0.15, 0.1) : SIMD3(0.57, 0, 0.8)
            list.add(.rect, center: SIMD2(timeLeft + timeW * 0.5, hudTop + tu * 0.5),
                     halfShape: SIMD2(timeW * 0.5 + tu * 0.5, tu * 0.75),
                     corner: tu * 0.6,
                     color: SIMD4(glowRGB.x, glowRGB.y, glowRGB.z, 0.10 + 0.12 * headPulse),
                     glowColor: glowRGB,
                     glowStrength: 0.7 + 0.5 * headPulse,
                     glowRadius: tu * (0.6 + 0.4 * headPulse))
        }
        let timeColor: SIMD4<Float> = danger ? rgba(1, 0.25, 0.2)
            : (game.fastDrain ? rgba(0.8, 0.45, 1) : rgba(1, 1, 1))
        atlas.append(timeText, into: &list, topLeft: SIMD2(timeLeft, hudTop),
                     pixelHeight: tu * 1.0, color: timeColor)
        // Score (right): anchored at its right edge so the zoom grows leftward.
        let scoreText = "\(game.score)/\(GameModel.winScore)"
        let scoreH = tu * 1.0 * scoreScale
        let scoreW = atlas.width(scoreText, pixelHeight: scoreH)
        atlas.append(scoreText, into: &list,
                     topLeft: SIMD2(layout.viewSize.x - tu * 3.2 - scoreW,
                                    hudTop - (scoreH - tu * 1.0) * 0.5),
                     pixelHeight: scoreH, color: rgba(1, 1, 1))

        // --- Eat-flash overlay (#5) ------------------------------------------
        if FX.reactiveMood && game.eatFlash > 0 {
            list.add(.rect, center: layout.viewSize * 0.5,
                     halfShape: layout.viewSize * 0.5, corner: 0,
                     color: rgba(1.0, 0.5, 0.35, game.eatFlash * 0.28), soft: 0)
        }

        // --- Game-over panel -------------------------------------------------
        if game.isGameOver {
            list.add(.rect, center: boardCenter,
                     halfShape: SIMD2(layout.boardW * 0.46, tu * 4.5),
                     corner: tu * 0.6, color: rgba(0, 0, 0, 0.72))
            atlas.appendCentered(game.won ? "You Win!" : "Game Over", into: &list,
                                 centerX: cx,
                                 top: boardCenter.y - tu * 3.2,
                                 pixelHeight: tu * 2.0,
                                 color: game.won ? rgba(0.5, 1, 0.6) : rgba(1, 1, 1))
            atlas.appendCentered("Score: \(game.score)", into: &list, centerX: cx,
                                 top: boardCenter.y - tu * 0.6,
                                 pixelHeight: tu * 1.2, color: rgba(1, 1, 1))
            atlas.appendCentered("Tap to restart", into: &list, centerX: cx,
                                 top: boardCenter.y + tu * 1.6,
                                 pixelHeight: tu * 1.1, color: rgba(1, 0.9, 0.2))
        }

        return list
    }

    /// The L-shape route the snake will follow: close the horizontal gap first,
    /// then the vertical. Cells from the head's next step through the destination
    /// (mirrors `GameModel.steerTowardDestination`, minus the reversal edge case).
    private func previewPath(from head: Point, to dest: Point) -> [Point] {
        var cells: [Point] = []
        var x = head.x
        let sx = dest.x > x ? 1 : (dest.x < x ? -1 : 0)
        while x != dest.x { x += sx; cells.append(Point(x: x, y: head.y)) }
        var y = head.y
        let sy = dest.y > y ? 1 : (dest.y < y ? -1 : 0)
        while y != dest.y { y += sy; cells.append(Point(x: dest.x, y: y)) }
        return cells
    }

    /// A base RGB stop hue-rotated by `turns` (in 0..1 turns), via HSV round-trip.
    private func rotatedStop(_ r: Double, _ g: Double, _ b: Double, by turns: Double) -> SIMD3<Float> {
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let v = mx, d = mx - mn
        let s = mx == 0 ? 0 : d / mx
        var h = 0.0
        if d != 0 {
            if mx == r       { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g  { h = (b - r) / d + 2 }
            else             { h = (r - g) / d + 4 }
            h /= 6
        }
        return hsv2rgb(h + turns, s, v)
    }
}

// MARK: - Metal renderer

/// Shader source, compiled at runtime so the whole app stays one Swift file
/// (no .metal resource to wire into the project). MSL here; the SDF math ports
/// near-verbatim to GLSL/AGSL on Android.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Instance {
    float4 a;     // center.xy, halfQuad.xy
    float4 b;     // halfShape.xy, corner(z), shapeID(w)
    float4 color;
    float4 glow;  // glow.rgb, strength
    float4 uv;    // origin.xy, size.zw
    float4 misc;  // soft(x), glowRadius(y), strokeThk(z), _
};

struct VSOut {
    float4 pos [[position]];
    float2 local;      // px relative to quad center
    float2 uv;         // atlas uv (glyph)
    float3 bgC;        // background gradient's third stop (rgb)
    float2 ndc01;      // 0..1 across the quad (background gradient)
    float4 color;
    float4 glow;
    float4 b;
    float4 misc;
};

vertex VSOut v_main(uint vid [[vertex_id]],
                    uint iid [[instance_id]],
                    constant Instance* insts [[buffer(0)]],
                    constant float2& viewport [[buffer(1)]]) {
    float2 corners[4] = { float2(-0.5,-0.5), float2(0.5,-0.5),
                          float2(-0.5, 0.5), float2(0.5, 0.5) };
    float2 c = corners[vid];
    Instance ins = insts[iid];
    float2 center   = ins.a.xy;
    float2 halfQuad = ins.a.zw;
    float2 px  = center + c * (halfQuad * 2.0);
    float2 ndc = (px / viewport) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    VSOut o;
    o.pos    = float4(ndc, 0.0, 1.0);
    o.local  = c * (halfQuad * 2.0);
    o.uv     = ins.uv.xy + (c + 0.5) * ins.uv.zw;
    o.bgC    = ins.uv.xyz;
    o.ndc01  = c + 0.5;
    o.color  = ins.color;
    o.glow   = ins.glow;
    o.b      = ins.b;
    o.misc   = ins.misc;
    return o;
}

static inline float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

fragment float4 f_main(VSOut in [[stage_in]],
                       texture2d<float> atlas [[texture(0)]],
                       sampler samp [[sampler(0)]]) {
    float shape     = in.b.w;
    float2 halfShape = in.b.xy;
    float corner    = in.b.z;
    float soft      = max(in.misc.x, 0.75);
    float glowR     = in.misc.y;
    float strokeThk = in.misc.z;
    float4 col      = in.color;

    if (shape == 3.0) {                       // glyph
        float a = atlas.sample(samp, in.uv).a;
        return float4(col.rgb, col.a * a);
    }
    if (shape == 4.0) {                       // background gradient
        float t = clamp((in.ndc01.x + in.ndc01.y) * 0.5, 0.0, 1.0);
        float3 A = in.color.rgb, B = in.glow.rgb, C = in.bgC;
        float3 g = (t < 0.5) ? mix(A, B, t * 2.0) : mix(B, C, (t - 0.5) * 2.0);
        return float4(g, 1.0);
    }

    // Spin the shape by rotating its local frame (misc.w = angle in radians).
    float2 lp = in.local;
    float rot = in.misc.w;
    if (rot != 0.0) {
        float ca = cos(rot), sa = sin(rot);
        lp = float2(ca * lp.x + sa * lp.y, -sa * lp.x + ca * lp.y);
    }

    float d;                                  // signed distance, <0 inside
    if (shape == 1.0) {                       // circle
        d = length(lp) - halfShape.x;
    } else if (shape == 2.0) {                // ring
        d = abs(length(lp) - halfShape.x) - strokeThk;
    } else if (shape == 5.0) {                // rounded-rect stroke
        d = abs(sdRoundBox(lp, halfShape, corner)) - strokeThk;
    } else {                                  // rounded/solid rect
        d = sdRoundBox(lp, halfShape, corner);
    }

    float fill  = 1.0 - smoothstep(0.0, soft, d);
    // Halo is deliberately dimmer than the fill so cores stay crisp.
    float gA    = (glowR > 0.0) ? exp(-max(d, 0.0) / glowR) * in.glow.a * 0.5 : 0.0;
    float fa    = col.a * fill;
    float ga    = gA * (1.0 - fill);
    float aout  = fa + ga;
    if (aout <= 0.0001) discard_fragment();
    float3 rgb  = (col.rgb * fa + in.glow.rgb * ga) / aout;
    return float4(rgb, aout);
}
"""

final class Renderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    let atlas: GlyphAtlas
    /// GPU time (ms) of the most recently completed frame. Written from the
    /// command buffer's completed handler; one frame of latency is fine for
    /// profiling. Double is not atomic, but a torn read once in a blue moon
    /// is acceptable for a debug metric.
    var lastGPUms: Double = 0

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice() else {
            print("Renderer: no Metal device"); return nil
        }
        guard let queue = device.makeCommandQueue() else {
            print("Renderer: no command queue"); return nil
        }
        guard let atlas = GlyphAtlas(device: device) else {
            print("Renderer: glyph atlas build failed"); return nil
        }
        self.device = device
        self.queue = queue
        self.atlas = atlas

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "v_main")
            desc.fragmentFunction = library.makeFunction(name: "f_main")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = mtkView.colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .sourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("Pipeline build failed: \(error)")
            return nil
        }

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        guard let samp = device.makeSamplerState(descriptor: sdesc) else { return nil }
        self.sampler = samp
    }

    func render(_ list: DrawList, in view: MTKView) {
        guard !list.instances.isEmpty,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        var viewport = SIMD2<Float>(Float(view.drawableSize.width),
                                    Float(view.drawableSize.height))
        let stride = MemoryLayout<GPUInstance>.stride
        let buffer = device.makeBuffer(bytes: list.instances,
                                       length: stride * list.instances.count,
                                       options: .storageModeShared)

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                           instanceCount: list.instances.count)
        enc.endEncoding()
        cmd.present(drawable)
        // Perf instrumentation: GPU time of the finished frame, read next
        // frame by the host's profiler (completed handlers run off-thread).
        cmd.addCompletedHandler { [weak self] done in
            self?.lastGPUms = (done.gpuEndTime - done.gpuStartTime) * 1000
        }
        cmd.commit()
    }
}

// MARK: - Host (UIKit + MTKView)

final class GameViewController: UIViewController, MTKViewDelegate, UIGestureRecognizerDelegate {
    private let game = GameModel()
    private var renderer: Renderer!
    private var scene: SceneBuilder!
    private var metalView: MTKView { view as! MTKView }

    // Animation phases driven off the wall clock (replacing SwiftUI animations).
    private var lastTime = CACurrentMediaTime()
    private var hueShift = 0.0
    private var dashTint: Float = 0          // eased 0→1 toward `isDashing`
    /// Phase of the body's fluid-color flow (advances with snake speed).
    private var fluidPhase = 0.0
    /// Score zoom animation: remaining time of the 0.5s in-out pulse.
    private var scoreAnim = 0.0
    private var lastScore = 0
    /// Frame profiler (FX.debugHud): one row per frame for the current run
    /// (frame-to-frame time split into tick/build/encode, plus GPU time);
    /// dumped to Documents as CSV when the run ends.
    private var perfLog: [(t: Double, frameMs: Double, tickMs: Double,
                           buildMs: Double, encodeMs: Double, gpuMs: Double,
                           instances: Int)] = []
    private var wasGameOver = false
    /// Most recent frame's board geometry, used to map taps → grid cells.
    private var lastLayout: Layout?
    /// True once the grid's row count has been fitted to the screen height.
    private var gridSized = false
    /// Buzz when the snake severs itself (model bumps `severanceCount`).
    private let severHaptic = UINotificationFeedbackGenerator()
    private var lastSeveranceCount = 0
    /// D-pad state: invisible hit-zone buttons, per-button press energy
    /// (1 on touch, easing to 0 over ~0.4s), and the press-tick haptic.
    private var padButtons: [UIButton] = []
    private var padPress: [Float] = [0, 0, 0, 0]
    private let padHaptic = UIImpactFeedbackGenerator(style: .light)

    /// Where the D-pad cross sits horizontally (options menu, persisted).
    private enum PadPosition: String, CaseIterable {
        case left, middle, right
        var xFraction: CGFloat {
            switch self {
            case .left:   return 0.28
            case .middle: return 0.5
            case .right:  return 0.72
            }
        }
    }
    private var padPosition = PadPosition(
        rawValue: UserDefaults.standard.string(forKey: "padPosition") ?? "") ?? .left

    /// Gap between button centers (options menu, persisted) — mis-presses
    /// were common with a tight cross, so spacing is user-tunable.
    private enum PadSpacing: String, CaseIterable {
        case narrow, normal, far
        var offset: CGFloat {
            switch self {
            case .narrow: return 74
            case .normal: return 86
            case .far:    return 98
            }
        }
    }
    private var padSpacing = PadSpacing(
        rawValue: UserDefaults.standard.string(forKey: "padSpacing") ?? "") ?? .normal
    /// "Sparks" quality dial (options menu, persisted): particle multiplier.
    private static let sparkTiers = [1, 2, 4, 8]
    private var optionsButton: UIButton?

    override func loadView() {
        let mtk = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtk.preferredFramesPerSecond = 60
        view = mtk
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let r = Renderer(mtkView: metalView) else {
            fatalError("Metal renderer unavailable")
        }
        renderer = r
        scene = SceneBuilder(atlas: r.atlas)
        metalView.delegate = self

        // Restore the persisted "Sparks" dial (0 = never set → x1).
        let savedFx = UserDefaults.standard.integer(forKey: "fxScale")
        if GameViewController.sparkTiers.contains(savedFx) { GameModel.fxScale = savedFx }

        // Gestures → InputIntent → model. Raw UIKit events never reach the model.
        // A single tap aims the snake at that cell (it auto-steers there, then
        // glides straight); double-tap dashes; a tap restarts on game over.
        setupOptionsButton()
        if Controls.dpad {
            // Steering and dashing live on the pad; a board tap only restarts
            // after game over (tap-dash was tried and misfired too easily).
            let tap = UITapGestureRecognizer(target: self, action: #selector(onRestartTap))
            tap.delegate = self
            view.addGestureRecognizer(tap)
            setupDPad()
        } else {
            let tap = UITapGestureRecognizer(target: self, action: #selector(onSingleTap(_:)))
            view.addGestureRecognizer(tap)
            let double = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
            double.numberOfTapsRequired = 2
            view.addGestureRecognizer(double)
            tap.require(toFail: double)   // so a dash double-tap doesn't also retarget
        }
    }

    // MARK: D-pad (experimental — see Controls.dpad)

    /// Console-style layout: a cross of four direction buttons on the left of
    /// the bottom strip. The UIButtons are invisible hit zones only; the pad's
    /// visuals are drawn through the Metal pipeline in `appendDPad` so it
    /// shares the game's neon look. Geometry for both comes from
    /// `dpadGeometry()` so they can't drift apart.
    private func setupDPad() {
        for i in 0..<4 {
            let b = UIButton(type: .custom)     // invisible; Metal draws the pad
            b.tag = i
            // touchDown, not touchUpInside: steering must fire the instant the
            // thumb lands, not on release.
            b.addTarget(self, action: #selector(onDPad(_:)), for: .touchDown)
            view.addSubview(b)
            padButtons.append(b)
        }
    }

    /// Cross center, horizontal/vertical distances to the button centers, and
    /// visible button size, in view points. The vertical spread clamps to the
    /// strip so the down button never runs past the bottom edge.
    private func dpadGeometry() -> (cross: CGPoint, hOffset: CGFloat, vOffset: CGFloat, size: CGFloat) {
        let b = view.bounds
        let stripTop = b.height * 0.72
        let stripH = b.height - stripTop
        let size: CGFloat = 70
        let h = padSpacing.offset
        let v = min(h, stripH / 2 - size / 2 - 6)
        return (CGPoint(x: b.width * padPosition.xFraction, y: stripTop + stripH / 2),
                h, v, size)
    }

    /// Button-center offsets by tag (up, down, left, right), unit lengths.
    private static let padOffsets: [(x: CGFloat, y: CGFloat)] = [(0, -1), (0, 1), (-1, 0), (1, 0)]
    /// Per-direction hues (up cyan, down violet, left orange, right magenta) —
    /// picked to not collide with the food palette.
    private static let padHues: [Double] = [0.5, 0.75, 0.08, 0.87]

    /// Gear button opening the options menu (top right, next to the HUD).
    private func setupOptionsButton() {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        b.tintColor = UIColor(white: 1, alpha: 0.55)
        b.showsMenuAsPrimaryAction = true
        b.menu = optionsMenu()
        view.addSubview(b)
        optionsButton = b
    }

    private func optionsMenu() -> UIMenu {
        let positions = PadPosition.allCases.map { pos in
            UIAction(title: pos.rawValue.capitalized,
                     state: padPosition == pos ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.padPosition = pos
                UserDefaults.standard.set(pos.rawValue, forKey: "padPosition")
                self.view.setNeedsLayout()                  // move the hit zones
                self.optionsButton?.menu = self.optionsMenu()   // refresh checkmark
            }
        }
        let spacings = PadSpacing.allCases.map { sp in
            UIAction(title: sp.rawValue.capitalized,
                     state: padSpacing == sp ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.padSpacing = sp
                UserDefaults.standard.set(sp.rawValue, forKey: "padSpacing")
                self.view.setNeedsLayout()
                self.optionsButton?.menu = self.optionsMenu()
            }
        }
        let sparks = GameViewController.sparkTiers.map { tier in
            UIAction(title: "\u{00D7}\(tier)",
                     state: GameModel.fxScale == tier ? .on : .off) { [weak self] _ in
                GameModel.fxScale = tier
                UserDefaults.standard.set(tier, forKey: "fxScale")
                self?.optionsButton?.menu = self?.optionsMenu()
            }
        }
        return UIMenu(children: [
            UIMenu(title: "D-Pad Position", options: .displayInline, children: positions),
            UIMenu(title: "Button Spacing", options: .displayInline, children: spacings),
            UIMenu(title: "Sparks", options: .displayInline, children: sparks),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        optionsButton?.frame = CGRect(x: view.bounds.width - 52,
                                      y: view.safeAreaInsets.top + 6,
                                      width: 44, height: 44)
        guard Controls.dpad else { return }
        let (cross, hOff, vOff, size) = dpadGeometry()
        let hit = size + 16     // touch slop beyond the visible button
        for (i, b) in padButtons.enumerated() {
            let o = GameViewController.padOffsets[i]
            b.frame = CGRect(x: cross.x + o.x * hOff - hit / 2,
                             y: cross.y + o.y * vOff - hit / 2,
                             width: hit, height: hit)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIButton)   // taps on pad buttons never count as dash
    }

    @objc private func onRestartTap() {
        if game.isGameOver { game.handle(.restart) }
    }

    @objc private func onDPad(_ sender: UIButton) {
        if game.isGameOver { game.handle(.restart); return }
        let dirs: [Direction] = [.up, .down, .left, .right]
        game.handle(.turn(dirs[sender.tag]))

        // Press feedback: glow surge, a light haptic tick, and a spray of
        // sparks in the button's color that joins the game's shard sim.
        padPress[sender.tag] = 1
        padHaptic.impactOccurred()
        if let layout = lastLayout {
            let scale = Float(view.contentScaleFactor)
            let (cross, hOff, vOff, _) = dpadGeometry()
            let o = GameViewController.padOffsets[sender.tag]
            let px = Float(cross.x + o.x * hOff) * scale
            let py = Float(cross.y + o.y * vOff) * scale
            game.emitSparks(x: Double((px - layout.boardX) / layout.cell),
                            y: Double((py - layout.boardY) / layout.cell),
                            hue: GameViewController.padHues[sender.tag], count: 10)
        }
    }

    /// Draw the pad through the same instanced SDF pipeline as the game:
    /// colored rounded buttons with chevrons, an idle breathing glow, and a
    /// flare + slight grow while a press's energy decays.
    private func appendDPad(into list: inout DrawList, now: Double) {
        let scale = Float(view.contentScaleFactor)
        let (cross, hOff, vOff, size) = dpadGeometry()
        // Chevron pattern is authored "pointing up" and rotated per direction.
        let angles: [Float] = [0, .pi, -.pi / 2, .pi / 2]

        // Center hub.
        list.add(.circle,
                 center: SIMD2(Float(cross.x) * scale, Float(cross.y) * scale),
                 halfShape: SIMD2(11 * scale, 11 * scale),
                 color: rgba(1, 1, 1, 0.07),
                 glowColor: SIMD3(0.5, 0.9, 1), glowStrength: 0.12, glowRadius: 4 * scale)

        for i in 0..<4 {
            let o = GameViewController.padOffsets[i]
            let cx = Float(cross.x + o.x * hOff) * scale
            let cy = Float(cross.y + o.y * vOff) * scale
            let press = padPress[i]
            // Idle breath: each button's brightness sways on its own phase.
            let breath = 0.5 + 0.5 * Float(sin(now * 1.8 + Double(i) * 1.6))
            let rgb = hsv2rgb(GameViewController.padHues[i], 0.8, 1.0)
            let half = Float(size) * 0.5 * scale * (1 + 0.12 * press)

            list.add(.rect, center: SIMD2(cx, cy), halfShape: SIMD2(half, half),
                     corner: half * 0.35,
                     color: SIMD4(rgb.x, rgb.y, rgb.z, 0.10 + 0.06 * breath + 0.45 * press),
                     glowColor: rgb,
                     glowStrength: 0.2 + 0.15 * breath + 1.0 * press,
                     glowRadius: (5 + 4 * breath + 24 * press) * scale)

            // Chevron: two slanted bars meeting at an apex, pointing outward.
            let theta = angles[i]
            for s: Float in [-1, 1] {
                let lx = s * 6.6 * scale, ly = Float(1.8) * scale
                let rx = lx * cos(theta) - ly * sin(theta)
                let ry = lx * sin(theta) + ly * cos(theta)
                list.add(.rect, center: SIMD2(cx + rx, cy + ry),
                         halfShape: SIMD2(8.4 * scale, 2.4 * scale), corner: 2.4 * scale,
                         color: SIMD4(1, 1, 1, 0.55 + 0.45 * press),
                         glowColor: rgb, glowStrength: 0.3 + 0.7 * press,
                         glowRadius: 3 * scale,
                         rot: s * 0.7 + theta)   // +: apex points outward (screen y-down)
            }
        }
    }

    // Let the game receive the first edge swipe instead of iOS pulling down
    // Notification Center / up Control Center. A deliberate second swipe still
    // reaches the system. Also hide the home indicator to calm the bottom edge.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: Input

    @objc private func onSingleTap(_ g: UITapGestureRecognizer) {
        if game.isGameOver { game.handle(.restart); return }
        // With the D-pad active, tap-to-target steering is disabled; taps on
        // the board do nothing (restart above still works).
        guard !Controls.dpad else { return }
        // Map the tap (view points) to a grid cell via the last frame's layout.
        guard let cell = cellAt(point: g.location(in: view)) else { return }
        game.handle(.setDestination(cell))
    }

    @objc private func onDoubleTap() { game.handle(.dash) }

    /// Convert a tap location in view points to a grid cell, or nil if no frame
    /// has been laid out yet. The layout works in drawable pixels, so scale up.
    private func cellAt(point p: CGPoint) -> Point? {
        guard let layout = lastLayout else { return nil }
        let scale = Float(view.contentScaleFactor)
        let px = Float(p.x) * scale
        let py = Float(p.y) * scale
        let col = Int((px - layout.boardX) / layout.cell)
        let row = Int((py - layout.boardY) / layout.cell)
        // setDestination clamps to the board, so off-board taps snap to an edge.
        return Point(x: col, y: row)
    }

    // MARK: Frame loop

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if !gridSized { gridSized = sizeGridToFillScreen(view: view) }

        let now = CACurrentMediaTime()
        let dtRaw = max(now - lastTime, 0)
        let dt = min(dtRaw, 0.1)
        lastTime = now

        game.tick(dt)
        let tTick = CACurrentMediaTime()

        if game.severanceCount != lastSeveranceCount {
            lastSeveranceCount = game.severanceCount
            severHaptic.notificationOccurred(.error)
        }

        // Advance phases: hue cycle (~13s), eased dash tint (0.2s), pulses.
        hueShift = (hueShift + dt * 0.076).truncatingRemainder(dividingBy: 1)
        let target: Float = game.isDashing ? 1 : 0
        dashTint += (target - dashTint) * min(1, Float(dt) / 0.2)
        let foodPulse = 0.5 + 0.5 * Float(sin(now * (2 * .pi / 1.4)))    // 1.4s period
        let headPulse = 0.5 + 0.5 * Float(sin(now * (2 * .pi / 0.9)))    // 0.9s period

        let layout = makeLayout(view: view)
        lastLayout = layout
        // Tell the model how far the screen's "sky" extends beyond the board
        // (in cell units) so finale fireworks can use the whole display.
        GameModel.skyAbove = Double(layout.boardY / layout.cell)
        GameModel.skyBelow = Double((layout.viewSize.y - layout.boardY
                                     - layout.boardH) / layout.cell)
        // Flows the path-preview pulse toward the destination (~0.9 cycles/sec).
        let pathPhase = Float(now * 0.9)
        // The body fluid drifts with the snake's speed (lava-lamp churn).
        fluidPhase = (fluidPhase + dt * 0.10 * game.effectiveSpeed)
            .truncatingRemainder(dividingBy: 1)
        // Score zoom: a 0.5s in-out pulse whenever a point lands.
        if game.score > lastScore { scoreAnim = 0.5 }
        lastScore = game.score
        scoreAnim = max(0, scoreAnim - dt)
        let scoreScale = Float(1 + 0.6 * sin((1 - scoreAnim / 0.5) * .pi))
        var list = scene.build(game: game, layout: layout, hueShift: hueShift,
                               foodPulse: foodPulse, headPulse: headPulse,
                               dashTint: dashTint, pathPhase: pathPhase,
                               fluidPhase: fluidPhase, scoreScale: scoreScale,
                               emberTime: now)
        if Controls.dpad {
            for i in 0..<4 { padPress[i] = max(0, padPress[i] - Float(dt) / 0.4) }
            appendDPad(into: &list, now: now)
        }

        let tBuild = CACurrentMediaTime()

        if FX.debugHud {
            // Live readout: frame-to-frame ms / GPU ms / instance count.
            // (Atlas charset covers digits, '.', '/', 'm', 's', space.)
            let text = String(format: "%.1f/%.1f ms  %d",
                              dtRaw * 1000, renderer.lastGPUms, list.instances.count)
            // Centered in the HUD line's free middle (countdown sits left,
            // score right) — clear of the notch/Dynamic Island.
            renderer.atlas.appendCentered(text, into: &list,
                                          centerX: layout.viewSize.x * 0.5,
                                          top: layout.boardY - layout.textUnit * 1.4,
                                          pixelHeight: layout.textUnit * 0.9,
                                          color: rgba(0.6, 1.0, 0.7, 0.8))
        }

        renderer.render(list, in: view)

        if FX.debugHud {
            let tEncode = CACurrentMediaTime()
            if perfLog.count < 60_000 {
                perfLog.append((t: now, frameMs: dtRaw * 1000,
                                tickMs: (tTick - now) * 1000,
                                buildMs: (tBuild - tTick) * 1000,
                                encodeMs: (tEncode - tBuild) * 1000,
                                gpuMs: renderer.lastGPUms,
                                instances: list.instances.count))
            }
            if game.isGameOver && !wasGameOver { dumpPerfLog() }
            if !game.isGameOver && wasGameOver { perfLog = [] }   // fresh run
            wasGameOver = game.isGameOver
        }
    }

    /// Write the run's frame log to Documents (pull it via devicectl).
    private func dumpPerfLog() {
        guard let dir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else { return }
        var csv = "t,frameMs,tickMs,buildMs,encodeMs,gpuMs,instances\n"
        let t0 = perfLog.first?.t ?? 0
        for r in perfLog {
            csv += String(format: "%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n",
                          r.t - t0, r.frameMs, r.tickMs, r.buildMs, r.encodeMs,
                          r.gpuMs, r.instances)
        }
        let url = dir.appendingPathComponent(
            String(format: "perf_%d_fx%d.csv", Int(Date().timeIntervalSince1970),
                   GameModel.fxScale))
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        print("PERF CSV written: \(url.path) (\(perfLog.count) frames)")
    }

    /// One-time at startup: with the cell size fixed by the board filling the
    /// width (13 cols), extend the row count so the board also fills the height
    /// between the HUD and the bottom of the screen. Returns false until the
    /// view has real geometry to measure.
    private func sizeGridToFillScreen(view: MTKView) -> Bool {
        // Rows are decided against the NOMINAL region (0.76h) with full-width
        // cells; the visible arena then scales into the smaller display
        // region (0.72h) without changing the grid.
        let (w, _, _, availH) = insetGeometry(view: view, bottomFraction: 0.76)
        guard w > 0, availH > 0 else { return false }
        let cell = w / Float(GameModel.cols + 2)   // +2: one-cell side margins
        let rows = max(8, Int(availH / cell))
        if rows != GameModel.rows {
            GameModel.rows = rows
            game.reset()   // re-center the snake and respawn food on the new grid
        }
        return true
    }

    /// Drawable size plus the vertical space reserved for HUD (top) and either
    /// the D-pad strip (bottom fifth) or a small bottom margin. Shared by grid
    /// sizing and per-frame layout so the two can't disagree.
    private func insetGeometry(view: MTKView, bottomFraction: Float) -> (w: Float, h: Float, topInset: Float, availH: Float) {
        let scale = Float(view.contentScaleFactor)
        let w = Float(view.drawableSize.width)
        let h = Float(view.drawableSize.height)
        let topInset = Float(self.view.safeAreaInsets.top) * scale + 34 * scale
        let boardBottom = Controls.dpad
            ? h * bottomFraction   // the strip below belongs to the D-pad
            : h - (Float(self.view.safeAreaInsets.bottom) * scale + 20 * scale)
        return (w, h, topInset, boardBottom - topInset)
    }

    /// Center the board horizontally; reserve room above it for the HUD text.
    /// The display region ends higher (0.72h) than the nominal one the rows
    /// were sized for, so the whole arena renders scaled-down and centered —
    /// same grid, smaller cells — leaving more room for the D-pad.
    private func makeLayout(view: MTKView) -> Layout {
        let (w, h, topInset, availH) = insetGeometry(view: view, bottomFraction: 0.72)
        let cell = min(w / Float(GameModel.cols + 2), availH / Float(GameModel.rows))
        let boardW = cell * Float(GameModel.cols)
        let boardH = cell * Float(GameModel.rows)
        let boardX = (w - boardW) * 0.5
        let boardY = topInset + (availH - boardH) * 0.5
        // Text size keyed to view width (≈ the pre-enlargement cell), so the HUD
        // keeps its old size even though the board's cells are now bigger.
        let textUnit = w * 0.05
        return Layout(viewSize: SIMD2(w, h), cell: cell, textUnit: textUnit,
                      boardX: boardX, boardY: boardY, boardW: boardW, boardH: boardH)
    }
}

// MARK: - Entry point

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = GameViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

// A file named `main.swift` is parsed as top-level/script code, so the app is
// launched with an explicit `UIApplicationMain` call rather than `@main`.
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv,
                  nil, NSStringFromClass(AppDelegate.self))
