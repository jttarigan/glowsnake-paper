package com.smoketest.snake.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// The pure simulation layer — a line-faithful Kotlin port of main.swift's
// model section. Structure, naming, and evaluation order mirror the Swift
// original so seeded runs produce identical draw lists (verified by the
// golden-trace test).

object FX {
    const val animatedBackground = true
    const val neonGrid = true
    const val eatParticles = true
    const val reactiveMood = true
    const val finaleFireworks = true
    const val ambientEmbers = true
    const val emberLights = true
    const val debugHud = true
    const val benchMaxFinale = true
}

object Controls {
    const val dpad = true
}

data class Point(val x: Int, val y: Int)

data class TrailMark(val id: Int, val point: Point, val age: Double)

data class Ripple(val id: Int, val center: Point, val hue: Double, val age: Double)

enum class FoodKind {
    GROW, SPEED, SCATTER, TIME, PENALTY;

    val hue: Double
        get() = when (this) {
            GROW -> 0.161
            SPEED -> 0.507
            SCATTER -> 0.427
            TIME -> 0.786
            PENALTY -> 0.920
        }

    fun randomShade(): Double = when (this) {
        GROW -> Rand.d(0.130, 0.192)
        SPEED -> Rand.d(0.470, 0.545)
        SCATTER -> Rand.d(0.395, 0.455)
        TIME -> Rand.d(0.750, 0.825)
        PENALTY -> Rand.d(0.890, 0.955)
    }

    companion object {
        val allCases = listOf(GROW, SPEED, SCATTER, TIME, PENALTY)
    }
}

class Food(var point: Point, val kind: FoodKind, val shade: Double = 0.0,
           var age: Double = 0.0)

class Particle(
    val id: Int,
    var x: Double, var y: Double,
    var vx: Double, var vy: Double,
    val hue: Double,
    var age: Double,
    val lifetime: Double,
    val size: Double,
    var angle: Double,
    val spin: Double,
    val gravity: Double = 0.0,
    val twinkle: Boolean = false,
)

class Firework(val ignition: Double, val x: Double, val y: Double,
               val shade: Double, var exploded: Boolean = false)

enum class Direction {
    UP, DOWN, LEFT, RIGHT;

    val dx: Int get() = when (this) { LEFT -> -1; RIGHT -> 1; else -> 0 }
    val dy: Int get() = when (this) { UP -> -1; DOWN -> 1; else -> 0 }

    fun isOpposite(other: Direction): Boolean = when (this to other) {
        UP to DOWN, DOWN to UP, LEFT to RIGHT, RIGHT to LEFT -> true
        else -> false
    }
}

data class DyingCell(val point: Point, val hue: Double)

class GameModel {
    companion object {
        const val cols = 11
        var rows = 18

        const val baseMoveInterval = 0.15
        const val dashMoveInterval = 0.075
        const val maxSpeedFactor = 3.0
        const val starveLimit = 10.0
        const val fastDrainRate = 1.25
        const val winScore = 30
        val unlockThresholds = listOf(
            5 to FoodKind.SPEED, 8 to FoodKind.SCATTER,
            12 to FoodKind.TIME, 16 to FoodKind.PENALTY)
        const val redRushSegments = 5
        const val redRushSpeedBoost = 1.5
        const val redCountdown = 5.0
        const val rushPopInterval = 0.05
        const val finaleMinDuration = 3.0
        const val finaleMaxDuration = 10.0
        const val finaleMinWindow = 0.4
        const val finaleMaxWindow = 3.0
        const val streakDuration = 0.35
        const val sparkGravity = 3.2
        var skyAbove = 2.5
        var skyBelow = 7.0
        const val foodSpawnInterval = 2.0
        const val maxFoods = 4
        const val foodLifetime = 5.0
        const val foodWarnTime = 3.0
        const val pelletHopInterval = 1.0
        const val baseSegmentHue = 0.42
        const val dashDuration = 0.5
        const val dashCooldown = 2.0
        const val dashFadeDuration = 0.6
        const val trailLifetime = 0.5
        const val rippleLifetime = 1.5
        const val rippleTravel = 9.5
        const val particleCount = 56
        var fxScale = 1
        const val particleLifeSmall = 2.0
        const val particleLifeLarge = 10.0
        const val particleDrag = 1.6
        const val particleRepelRadius = 1.4
        const val particleRepelForce = 30.0
        const val eatFlashDuration = 0.4
    }

    var snake = mutableListOf<Point>()
    var prevSnake = listOf<Point>()
        private set
    var segmentHues = mutableListOf<Double>()
    var fastDrain = false
    var redRush = false
    var won = false
    var isDying = false
    var dyingCells = mutableListOf<DyingCell>()
    private var dyingTimer = 0.0
    var fireworks = mutableListOf<Firework>()
    var finaleClock = 0.0
    private var finaleDuration = 0.0
    var foods = mutableListOf<Food>()
    var pelletsRestless = false
    private var pelletHopTimer = 0.0
    var speedFactor = 1.0
    var destination: Point? = null
    var score = 0
    var isGameOver = false
    var severanceCount = 0
    var timeRemaining = 10.0
    val moveProgress: Double
        get() {
            val interval = (if (dashTimeRemaining > 0) dashMoveInterval
                            else baseMoveInterval) / effectiveSpeed
            return min(1.0, max(0.0, moveAccumulator / interval))
        }
    var dashReady = true
    var isDashing = false
    var dashGlow = 0.0
    var trail = mutableListOf<TrailMark>()
    var ripples = mutableListOf<Ripple>()
    var particles = mutableListOf<Particle>()
    var eatFlash = 0.0

    private var direction = Direction.RIGHT
    private var pendingDirection = Direction.RIGHT
    private var moveAccumulator = 0.0
    private var dashTimeRemaining = 0.0
    private var dashCooldownRemaining = 0.0
    private var foodSpawnTimer = 0.0
    private var pendingGrowth = 0
    private var pendingHues = mutableListOf<Double>()
    private var rushPopsRemaining = 0
    private var rushPopTimer = 0.0
    private var rushBurstCells = mutableListOf<Point>()
    var highWater = 0
        private set
    val unlockedKinds: List<FoodKind>
        get() = listOf(FoodKind.GROW) +
            unlockThresholds.filter { highWater >= it.first }.map { it.second }
    var recentMeals = mutableListOf<Double>()
        private set
    val effectiveSpeed: Double
        get() = speedFactor * (if (redRush) redRushSpeedBoost else 1.0)
    private var trailCounter = 0
    private var rippleCounter = 0
    private var particleCounter = 0

    init {
        reset()
    }

    fun reset() {
        val midY = rows / 2
        snake = mutableListOf(Point(3, midY), Point(4, midY), Point(5, midY))
        prevSnake = snake.toList()
        segmentHues = MutableList(snake.size) { baseSegmentHue }
        fastDrain = false
        redRush = false
        won = false
        isDying = false
        dyingCells = mutableListOf()
        dyingTimer = 0.0
        fireworks = mutableListOf()
        finaleClock = 0.0
        finaleDuration = 0.0
        pendingGrowth = 0
        pendingHues = mutableListOf()
        highWater = 0
        recentMeals = mutableListOf()
        rushPopsRemaining = 0
        rushPopTimer = 0.0
        rushBurstCells = mutableListOf()
        direction = Direction.RIGHT
        pendingDirection = Direction.RIGHT
        destination = null
        score = 0
        isGameOver = false
        timeRemaining = starveLimit
        moveAccumulator = 0.0
        dashTimeRemaining = 0.0
        dashCooldownRemaining = 0.0
        dashReady = true
        isDashing = false
        dashGlow = 0.0
        trail = mutableListOf()
        trailCounter = 0
        ripples = mutableListOf()
        rippleCounter = 0
        particles = mutableListOf()
        particleCounter = 0
        eatFlash = 0.0
        foods = mutableListOf()
        pelletsRestless = false
        pelletHopTimer = 0.0
        speedFactor = 1.0
        foodSpawnTimer = foodSpawnInterval
        spawnFood()
    }

    /** Aim the snake at a cell (Swift's setDestination; renamed to avoid a
     *  JVM clash with the `destination` property's setter). */
    fun aim(p: Point) {
        if (isGameOver) return
        val x = min(max(p.x, 0), cols - 1)
        val y = min(max(p.y, 0), rows - 1)
        destination = Point(x, y)
    }

    private fun steerTowardDestination() {
        val dest = destination ?: return
        val head = snake.lastOrNull() ?: return
        if (head == dest) { destination = null; return }

        val preferred = mutableListOf<Direction>()
        if (dest.x != head.x) preferred.add(if (dest.x > head.x) Direction.RIGHT else Direction.LEFT)
        if (dest.y != head.y) preferred.add(if (dest.y > head.y) Direction.DOWN else Direction.UP)

        for (dir in preferred) {
            if (!dir.isOpposite(direction)) {
                pendingDirection = dir
                return
            }
        }
    }

    fun turn(dir: Direction) {
        if (isGameOver || isDying || dir.isOpposite(direction)) return
        destination = null
        pendingDirection = dir
    }

    fun triggerDash() {
        if (isGameOver || dashCooldownRemaining > 0 || dashTimeRemaining > 0) return
        dashTimeRemaining = dashDuration
        dashCooldownRemaining = dashCooldown
        dashReady = false
    }

    fun tick(dt: Double) {
        if (isGameOver) return

        if (isDying) {
            ageEffects(dt)
            if (dyingCells.isNotEmpty()) {
                dyingTimer += dt
                while (dyingTimer >= rushPopInterval && dyingCells.isNotEmpty()) {
                    dyingTimer -= rushPopInterval
                    val victim = dyingCells.removeAt(Rand.iExcl(0, dyingCells.size))
                    burst(victim.point, victim.hue, 36,
                          sizesLo = 0.04, sizesHi = 0.26, hueSpread = 0.12,
                          speedsLo = 1.5, speedsHi = 12.0)
                }
            } else {
                finaleClock += dt
                for (fw in fireworks) {
                    if (!fw.exploded && fw.ignition <= finaleClock) {
                        fw.exploded = true
                        igniteFirework(fw)
                    }
                }
                if (finaleClock >= finaleDuration && particles.none { it.twinkle }) {
                    isGameOver = true
                }
            }
            return
        }

        timeRemaining -= dt * (if (fastDrain) fastDrainRate else 1.0)
        if (timeRemaining <= 0) {
            timeRemaining = 0.0
            beginFinale()
            return
        }

        if (rushPopsRemaining > 0) {
            rushPopTimer += dt
            while (rushPopTimer >= rushPopInterval && rushPopsRemaining > 0) {
                rushPopTimer -= rushPopInterval
                rushPopsRemaining -= 1
                rushBurstCells.removeLastOrNull()?.let { cell ->
                    burst(cell, FoodKind.PENALTY.hue, 10)
                }
                if (snake.size > 1) {
                    snake.removeAt(0)
                    segmentHues.removeAt(0)
                }
            }
        } else {
            rushPopTimer = 0.0
        }

        dashTimeRemaining = max(0.0, dashTimeRemaining - dt)
        dashCooldownRemaining = max(0.0, dashCooldownRemaining - dt)
        dashReady = dashCooldownRemaining <= 0
        isDashing = dashTimeRemaining > 0
        if (dashTimeRemaining > 0) {
            dashGlow = 1.0
        } else {
            dashGlow = max(0.0, dashGlow - dt / dashFadeDuration)
        }

        ageEffects(dt)

        foodSpawnTimer -= dt
        if (foodSpawnTimer <= 0) {
            if (foods.size < maxFoods) spawnFood()
            foodSpawnTimer = foodSpawnInterval
        }

        for (f in foods) {
            f.age += dt
            if (f.age >= foodLifetime) {
                explodeFood(f)
                freeCell()?.let { cell ->
                    f.point = cell
                    spawnShimmer(cell, f.shade)
                }
                f.age = 0.0
            }
        }

        if (pelletsRestless) {
            pelletHopTimer += dt
            if (pelletHopTimer >= pelletHopInterval) {
                pelletHopTimer -= pelletHopInterval
                for (f in foods) {
                    val open = listOf(Direction.UP, Direction.DOWN,
                                      Direction.LEFT, Direction.RIGHT)
                        .mapNotNull { dir ->
                            val n = Point(f.point.x + dir.dx, f.point.y + dir.dy)
                            if (n.x in 0 until cols && n.y in 0 until rows &&
                                !snake.contains(n) &&
                                foods.none { it.point == n }) n else null
                        }
                    Rand.pick(open)?.let { f.point = it }
                }
            }
        } else {
            pelletHopTimer = 0.0
        }

        val interval = (if (dashTimeRemaining > 0) dashMoveInterval
                        else baseMoveInterval) / effectiveSpeed
        moveAccumulator += dt
        while (moveAccumulator >= interval && !isGameOver) {
            moveAccumulator -= interval
            step()
        }
    }

    private fun step() {
        if (isGameOver) return
        prevSnake = snake.toList()
        steerTowardDestination()
        direction = pendingDirection

        val last = snake.lastOrNull() ?: return
        var hx = last.x + direction.dx
        var hy = last.y + direction.dy

        hx = (hx + cols) % cols
        hy = (hy + rows) % rows
        val head = Point(hx, hy)

        if (pendingGrowth > 0) {
            pendingGrowth -= 1
            segmentHues.add(0, if (pendingHues.isEmpty()) baseSegmentHue
                               else pendingHues.removeAt(0))
        } else if (snake.isNotEmpty()) {
            val tail = snake.first()
            trail.add(TrailMark(trailCounter, tail, 0.0))
            trailCounter += 1
            snake.removeAt(0)
        }

        val hit = snake.indexOf(head)
        if (hit >= 0) {
            val severed = snake.subList(0, hit + 1).toList()
            val severedHues = segmentHues.subList(0, hit + 1).toList()
            repeat(hit + 1) { snake.removeAt(0); segmentHues.removeAt(0) }
            explode(severed, severedHues)
            severanceCount += 1
            score -= severed.size
        }

        snake.add(head)
        val i = foods.indexOfFirst { it.point == head }
        if (i >= 0) {
            apply(foods.removeAt(i))
        }
    }

    private fun apply(eaten: Food) {
        if (redRush) expireRedRush()
        fastDrain = false

        val before = unlockedKinds.size
        score += 1
        highWater = max(highWater, score)
        timeRemaining = starveLimit
        recentMeals.add(eaten.shade)
        if (recentMeals.size > 5) recentMeals.removeAt(0)
        when (eaten.kind) {
            FoodKind.GROW -> {
                pendingGrowth += 1
                pendingHues.add(eaten.shade)
            }
            FoodKind.SPEED ->
                speedFactor = min(speedFactor * 1.05, maxSpeedFactor)
            FoodKind.SCATTER ->
                pelletsRestless = !pelletsRestless
            FoodKind.TIME ->
                fastDrain = true
            FoodKind.PENALTY -> {
                redRush = true
                pendingGrowth += redRushSegments
                repeat(redRushSegments) { pendingHues.add(eaten.kind.hue) }
                timeRemaining = redCountdown
            }
        }

        if (unlockedKinds.size > before) {
            unlockedKinds.lastOrNull()?.let { announceUnlock(it) }
        }
        if (score >= winScore) {
            beginFinale()
            return
        }

        ripples.add(Ripple(rippleCounter, eaten.point, eaten.shade, 0.0))
        rippleCounter += 1
        if (FX.eatParticles) {
            val cx = eaten.point.x.toDouble() + 0.5
            val cy = eaten.point.y.toDouble() + 0.5
            val n = particleCount * fxScale
            for (k in 0 until n) {
                val angle = (k.toDouble() / n.toDouble()) * 2 * PI + Rand.d(-0.3, 0.3)
                val speed = Rand.d(2.5, 11.0)
                val size = Rand.d(0.10, 0.22)
                particles.add(Particle(particleCounter, cx, cy,
                    cos(angle) * speed, sin(angle) * speed,
                    eaten.shade + Rand.d(-0.03, 0.03), 0.0,
                    shardLifetime(size, 0.10, 0.22),
                    size,
                    Rand.d(0.0, 2 * PI),
                    Rand.d(-5.0, 5.0)))
                particleCounter += 1
            }
        }
        if (FX.reactiveMood) eatFlash = 1.0
    }

    private fun explode(cells: List<Point>, hues: List<Double>) {
        val breakPoint = cells.lastOrNull() ?: return
        ripples.add(Ripple(rippleCounter, breakPoint, -1.0, 0.0))
        rippleCounter += 1
        for ((i, c) in cells.withIndex()) {
            val cx = c.x.toDouble() + 0.5
            val cy = c.y.toDouble() + 0.5
            val hue = if (i < hues.size) hues[i] else 0.0
            repeat(12 * fxScale) {
                val angle = Rand.d(0.0, 2 * PI)
                val speed = Rand.d(3.0, 14.0)
                val size = Rand.d(0.08, 0.20)
                particles.add(Particle(particleCounter, cx, cy,
                    cos(angle) * speed, sin(angle) * speed,
                    hue + Rand.d(-0.05, 0.05), 0.0,
                    shardLifetime(size, 0.08, 0.20),
                    size,
                    Rand.d(0.0, 2 * PI),
                    Rand.d(-12.0, 12.0)))
                particleCounter += 1
            }
        }
    }

    private fun expireRedRush() {
        redRush = false
        val redHue = FoodKind.PENALTY.hue
        val queued = pendingHues.count { it == redHue }
        pendingGrowth -= queued
        pendingHues.removeAll { it == redHue }
        val cells = Rand.shuffled(
            snake.zip(segmentHues).filter { it.second == redHue }.map { it.first })
        rushBurstCells.addAll(cells)
        rushPopsRemaining += cells.size
    }

    private fun ageEffects(dt: Double) {
        trail = trail.mapNotNull { mark ->
            val aged = mark.age + dt
            if (aged >= trailLifetime) null else TrailMark(mark.id, mark.point, aged)
        }.toMutableList()
        ripples = ripples.mapNotNull { r ->
            val aged = r.age + dt
            if (aged >= rippleLifetime) null else Ripple(r.id, r.center, r.hue, aged)
        }.toMutableList()
        val drag = exp(-dt * particleDrag)
        val repelR = particleRepelRadius
        val kept = mutableListOf<Particle>()
        for (q in particles) {
            q.age += dt
            if (q.age >= q.lifetime) continue
            var fx = 0.0
            var fy = 0.0
            for (s in snake) {
                val dx = q.x - (s.x.toDouble() + 0.5)
                val dy = q.y - (s.y.toDouble() + 0.5)
                val d2 = dx * dx + dy * dy
                if (d2 >= repelR * repelR || d2 <= 0.0001) continue
                val d = sqrt(d2)
                val f = particleRepelForce * (1 - d / repelR) / max(d, 0.3)
                fx += dx * f
                fy += dy * f
            }
            q.vx = q.vx * drag + fx * dt
            q.vy = q.vy * drag + (fy + q.gravity) * dt
            q.x += q.vx * dt
            q.y += q.vy * dt
            q.angle += q.spin * dt
            kept.add(q)
        }
        particles = kept
        eatFlash = max(0.0, eatFlash - dt / eatFlashDuration)
    }

    private fun beginFinale() {
        isDying = true
        won = true
        dyingTimer = 0.0
        dyingCells = snake.zip(segmentHues)
            .map { DyingCell(it.first, it.second) }.toMutableList()
        snake = mutableListOf()
        prevSnake = listOf()
        segmentHues = mutableListOf()
        foods = mutableListOf()
        fireworks = mutableListOf()
        finaleClock = 0.0
        val n = if (FX.benchMaxFinale) winScore
                else max(0, min(score, winScore))
        val t = if (n <= 1) 0.0 else (n - 1).toDouble() / (winScore - 1).toDouble()
        finaleDuration = if (n == 0) 1.5
            else finaleMinDuration + (finaleMaxDuration - finaleMinDuration) * t
        val window = finaleMinWindow + (finaleMaxWindow - finaleMinWindow) * t
        if (!FX.finaleFireworks) return
        val skyTop = 1 - skyAbove
        val skyBottom = rows.toDouble() + skyBelow - 1.5
        val palette = Rand.shuffled(FoodKind.allCases)
        for (i in 0 until n) {
            fireworks.add(Firework(
                Rand.d(0.0, window),
                Rand.d(0.8, cols.toDouble() - 0.8),
                Rand.d(skyTop, skyBottom),
                palette[i % palette.size].randomShade()))
        }
    }

    private fun igniteFirework(f: Firework) {
        if (!FX.eatParticles) return
        val remaining = max(1.2, finaleDuration - f.ignition)
        repeat(Rand.i(50, 80) * fxScale) {
            val angle = Rand.d(0.0, 2 * PI)
            val speed = Rand.d(2.5, 8.0)
            particles.add(Particle(particleCounter, f.x, f.y,
                cos(angle) * speed, sin(angle) * speed,
                f.shade + Rand.d(-0.05, 0.05), 0.0,
                Rand.d(0.45 * remaining, remaining),
                Rand.d(0.05, 0.15),
                Rand.d(0.0, 2 * PI),
                Rand.d(-8.0, 8.0),
                gravity = sparkGravity,
                twinkle = true))
            particleCounter += 1
        }
    }

    private fun burst(cell: Point, hue: Double, count: Int,
                      sizesLo: Double = 0.06, sizesHi: Double = 0.15,
                      hueSpread: Double = 0.04,
                      speedsLo: Double = 2.0, speedsHi: Double = 9.0) {
        if (!FX.eatParticles) return
        val cx = cell.x.toDouble() + 0.5
        val cy = cell.y.toDouble() + 0.5
        repeat(count * fxScale) {
            val angle = Rand.d(0.0, 2 * PI)
            val speed = Rand.d(speedsLo, speedsHi)
            val size = Rand.d(sizesLo, sizesHi)
            particles.add(Particle(particleCounter, cx, cy,
                cos(angle) * speed, sin(angle) * speed,
                hue + Rand.d(-hueSpread, hueSpread), 0.0,
                Rand.d(0.5, 1.4),
                size,
                Rand.d(0.0, 2 * PI),
                Rand.d(-10.0, 10.0)))
            particleCounter += 1
        }
    }

    private fun announceUnlock(kind: FoodKind) {
        val center = Point(cols / 2, rows / 2)
        ripples.add(Ripple(rippleCounter, center, kind.hue, 0.0))
        rippleCounter += 1
        burst(center, kind.hue, 16)
    }

    fun emitSparks(x: Double, y: Double, hue: Double, count: Int) {
        repeat(count * fxScale) {
            val angle = Rand.d(0.0, 2 * PI)
            val speed = Rand.d(1.5, 6.0)
            val size = Rand.d(0.05, 0.13)
            particles.add(Particle(particleCounter, x, y,
                cos(angle) * speed,
                sin(angle) * speed - 2.5,
                hue + Rand.d(-0.04, 0.04), 0.0,
                Rand.d(0.6, 1.6),
                size,
                Rand.d(0.0, 2 * PI),
                Rand.d(-8.0, 8.0)))
            particleCounter += 1
        }
    }

    private fun shardLifetime(size: Double, rangeLo: Double, rangeHi: Double): Double {
        val norm = (size - rangeLo) / (rangeHi - rangeLo)
        val base = particleLifeSmall + (particleLifeLarge - particleLifeSmall) * norm
        return min(particleLifeLarge, base * Rand.d(0.85, 1.15))
    }

    private fun freeCell(): Point? {
        val occupied = HashSet<String>()
        for (s in snake) occupied.add("${s.x},${s.y}")
        for (f in foods) occupied.add("${f.point.x},${f.point.y}")
        val free = mutableListOf<Point>()
        for (y in 0 until rows) {
            for (x in 0 until cols) {
                if (!occupied.contains("$x,$y")) free.add(Point(x, y))
            }
        }
        return Rand.pick(free)
    }

    private fun spawnFood() {
        val pick = freeCell() ?: return
        val kind = Rand.pick(unlockedKinds) ?: return
        val shade = kind.randomShade()
        foods.add(Food(pick, kind, shade))
        spawnShimmer(pick, shade)
    }

    private fun spawnShimmer(cell: Point, hue: Double) {
        if (!FX.eatParticles) return
        val cx = cell.x.toDouble() + 0.5
        val cy = cell.y.toDouble() + 0.5
        repeat(14 * fxScale) {
            val angle = Rand.d(0.0, 2 * PI)
            val speed = Rand.d(1.0, 4.5)
            val size = Rand.d(0.06, 0.15)
            particles.add(Particle(particleCounter, cx, cy,
                cos(angle) * speed, sin(angle) * speed,
                hue + Rand.d(-0.05, 0.05), 0.0,
                shardLifetime(size, 0.06, 0.15),
                size,
                Rand.d(0.0, 2 * PI),
                Rand.d(-5.0, 5.0)))
            particleCounter += 1
        }
    }

    private fun explodeFood(f: Food) {
        if (!FX.eatParticles) return
        val cx = f.point.x.toDouble() + 0.5
        val cy = f.point.y.toDouble() + 0.5
        repeat(18 * fxScale) {
            val angle = Rand.d(0.0, 2 * PI)
            val speed = Rand.d(2.0, 8.0)
            val size = Rand.d(0.07, 0.17)
            particles.add(Particle(particleCounter, cx, cy,
                cos(angle) * speed, sin(angle) * speed,
                f.shade + Rand.d(-0.03, 0.03), 0.0,
                Rand.d(0.6, 1.6),
                size,
                Rand.d(0.0, 2 * PI),
                Rand.d(-8.0, 8.0)))
            particleCounter += 1
        }
    }
}
