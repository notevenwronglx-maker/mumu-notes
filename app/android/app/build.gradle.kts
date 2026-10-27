import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = listOf(
    rootProject.file("key.properties"),
    rootProject.file("keystore.properties")
).firstOrNull { it.exists() }
if (keystorePropertiesFile != null) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "dev.linwood.butterfly"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Flutter-friendly toggles:
    // - Env: USE_LEGACY_PACKAGING=true
    val useLegacy = (System.getenv("USE_LEGACY_PACKAGING") ?: "false").toBoolean()

    packaging {
        jniLibs {
            useLegacyPackaging = useLegacy
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    flavorDimensions += "default"
    productFlavors {
        create("production") {
            isDefault = true
            dimension = "default"
            applicationIdSuffix = ""
            manifestPlaceholders["appName"] = "木木笔记"
        }
        create("development") {
            dimension = "default"
            applicationIdSuffix = ""
            manifestPlaceholders["appName"] = "木木笔记"
        }
        create("nightly") {
            dimension = "default"
            applicationIdSuffix = ".nightly"
            manifestPlaceholders["appName"] = "木木笔记"
        }
    }

    sourceSets {
        getByName("nightly") {
            setRoot("src/development")
        }
    }

    defaultConfig {
        applicationId = "dev.linwood.butterfly"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = 29003
        versionName = "2.6.4"
    }

    signingConfigs {
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
            enableV4Signing = true
        }
        create("release") {
            val releaseStoreFile = keystoreProperties["storeFile"] as String?
            if (releaseStoreFile != null) {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = file(releaseStoreFile)
                storePassword = keystoreProperties["storePassword"] as String?
            }
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
            enableV4Signing = true
        }
    }

    buildTypes {
        release {
            // Prevent R8 from obfuscating Kotlin Continuation / SharedPreferencesApiRegistrar.getAll
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = if (keystoreProperties["storeFile"] != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
    dependenciesInfo {
        // Disables dependency metadata when building APKs.
        includeInApk = false
        // Disables dependency metadata when building Android App Bundles.
        includeInBundle = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget("17")
    }
}

dependencies {
    implementation(project(":palm-guard"))
    implementation("androidx.core:core-ktx:1.15.0")
}

flutter {
    source = "../.."
}
