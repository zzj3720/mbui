// The Android host of the MoonBit UI prototype: a GLSurfaceView driving
// libmbui.so (the MoonBit app as C, the runtime, and android_host.c),
// built by scripts/android.sh into src/main/jniLibs.
//
// Two builds: debug (dev.mbui.demo, "MoonBit UI": what scripts/android.sh, e2e/run.sh and CI build) and release, the
// beta test app (fail.still.mbui, "still.fail mbui", scripts/beta.sh and .github/workflows/beta.yml): a separate app,
// installable beside still.fail's own (fail.still.android, fail.still.android.beta) and the debug build, minified,
// signed with its own key when MBUI_KEYSTORE (a path), MBUI_KEYSTORE_PASSWORD, MBUI_KEY_ALIAS and MBUI_KEY_PASSWORD
// are set (unsigned otherwise). MBUI_VERSION_CODE and MBUI_VERSION_NAME: the build's number and name (CI: the run
// number, and the commit).
plugins {
    id("com.android.application")
}

fun env(name: String): String? = providers.environmentVariable(name).orNull?.takeIf { it.isNotEmpty() }

android {
    namespace = "dev.mbui"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.mbui.demo"
        minSdk = 29
        targetSdk = 36
        versionCode = env("MBUI_VERSION_CODE")?.toInt() ?: 1
        versionName = env("MBUI_VERSION_NAME") ?: "0.1.0"
        ndk { abiFilters += "arm64-v8a" }
        manifestPlaceholders["appLabel"] = "MoonBit UI"
    }
    // What an app with the still.fail core adds (APP=coredemo): the engine's and the shell's .so files and the core's
    // bytecode, which scripts/android.sh puts in out/android/apk (empty for the other apps).
    sourceSets.getByName("main") {
        jniLibs.srcDir("../../out/android/apk/jniLibs")
        assets.srcDir("../../out/android/apk/assets")
    }
    signingConfigs {
        val store = env("MBUI_KEYSTORE")
        if (store != null) create("beta") {
            storeFile = file(store)
            storePassword = env("MBUI_KEYSTORE_PASSWORD")
            keyAlias = env("MBUI_KEY_ALIAS")
            keyPassword = env("MBUI_KEY_PASSWORD")
        }
    }
    buildTypes {
        getByName("release") {
            manifestPlaceholders["appLabel"] = "still.fail mbui"
            // R8 over the Java (Media3's most of it) and unused resources; the host's classes are kept whole
            // (proguard-rules.pro: the C calls into them by name).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("beta")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// The beta app's own package (an applicationId per build type is not something buildTypes can say; a suffix is).
// Its native libraries compressed in the APK (stored, as minSdk 29 has them by default, it was 27 MB; 12.5 MB): a
// download, every build, for phones; installed, they are unpacked once.
androidComponents {
    onVariants(selector().withBuildType("release")) {
        it.applicationId.set("fail.still.mbui")
        it.packaging.jniLibs.useLegacyPackaging.set(true)
    }
}

// Native views over the canvas (NativeViews.java): the video player is Media3's ExoPlayer, as still.fail's Android
// app's (its version there, apps/android/gradle/libs.versions.toml).
dependencies {
    implementation("androidx.media3:media3-exoplayer:1.8.0")
    implementation("androidx.media3:media3-datasource:1.8.0")
}
