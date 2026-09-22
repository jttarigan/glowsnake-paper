// The Android host + GLES renderer (the platform layer below the DrawList
// seam). Framework-only, like the iOS side: no third-party dependencies.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.smoketest.snake"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.smoketest.snake"
        minSdk = 24          // GLES 3.0 guaranteed
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            // Benchmark builds must be optimized (lesson learned on iOS:
            // unoptimized builds made the scene builder ~30x slower). Signed
            // with the debug key so `adb install` works without a keystore.
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":core"))
}
