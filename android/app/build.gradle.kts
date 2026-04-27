plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.busboss.bus_boss_v2"
    // Logic Correction: Raised to 36 to satisfy the requirement of your 
    // updated native library stack (sqlite3 v3 / Native Assets).
    compileSdk = 36 
    
    // NDK r27 is correct for the Dart 3.9.999 toolchain.
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "com.busboss.bus_boss_v2"
        minSdk = 24 // Recommended floor for modern transit apps
        targetSdk = 35 
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            // Using debug config for now as per your workflow
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
