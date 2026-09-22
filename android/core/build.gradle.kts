// The portable layer: GameModel + SceneBuilder ported from main.swift.
// Pure Kotlin/JVM — no Android types — so golden-trace verification against
// the Swift harness runs on the Mac with no device or emulator.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    testImplementation(kotlin("test"))
}
