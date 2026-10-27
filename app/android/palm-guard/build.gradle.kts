import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// 自研电容笔防误触流水线 —— 独立可发布模块 (:palm-guard)
// 与 Butterfly 的 AGP 9.4.1 内置 Kotlin 编译器无缝对齐。
plugins {
    id("com.android.library")
}

android {
    namespace = "com.mumunotes.core.touch"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests {
            isReturnDefaultValues = true
        }
    }

    lint {
        checkDependencies = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget("17")
        freeCompilerArgs.add("-opt-in=kotlin.RequiresOptIn")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.annotation:annotation:1.9.1")

    testImplementation("junit:junit:4.13.2")
}
