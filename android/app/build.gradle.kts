plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// This is bi0shacker001's personal fork of caprado/romgi, maintained on
// feature branches that patch/extend the upstream app. Every build uses a
// bi0shacker001-scoped package id and "romgi-bio" label (distinct from
// upstream's com.caprado.romgi / "romgi") so it installs alongside the
// original app instead of overwriting it; non-main branches additionally
// get a branch-specific suffix so branch builds can coexist with each
// other and with main too. Branch name comes from CI (GITHUB_HEAD_REF for
// pull_request events, GITHUB_REF_NAME for push events); local/non-CI
// builds see neither and resolve to the plain main identity.
val ciBranch = (System.getenv("GITHUB_HEAD_REF")?.takeIf { it.isNotEmpty() }
    ?: System.getenv("GITHUB_REF_NAME"))
    ?.takeIf { it != "main" }
val branchSlug = ciBranch
    ?.replace(Regex("[^a-zA-Z0-9]+"), "_")
    ?.lowercase()
    ?.let { if (it.firstOrNull()?.isDigit() == true) "b_$it" else it }

val isFeatureBranch = branchSlug != null

// Feature-branch builds are rolling releases — every push replaces the
// previous one under the same tag without pubspec.yaml's version ever
// changing, so every build on a branch would otherwise report the exact
// same version with no way to tell which one is actually installed.
// revision.txt holds a plain integer, bumped by CI (see the "Bump build
// revision" step in pr-checks.yml) on every push to a feature branch, and
// stamped onto versionName below as "-rN". It's reset to a fresh count
// whenever a new feature branch is cut from main — main itself never
// reads it (isFeatureBranch is false there), so it doesn't need the file.
val revisionFile = file("revision.txt")
val buildRevision = if (isFeatureBranch && revisionFile.exists()) {
    revisionFile.readText().trim().toIntOrNull()
} else {
    null
}

android {
    namespace = "com.caprado.romgi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Enable core library desugaring for flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = if (branchSlug != null) {
            "com.bi0shacker001.romgi.branch.$branchSlug"
        } else {
            "com.bi0shacker001.romgi"
        }
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = if (buildRevision != null) {
            "${flutter.versionName}-r$buildRevision"
        } else {
            flutter.versionName
        }
        multiDexEnabled = true

        manifestPlaceholders["appLabel"] =
            if (ciBranch != null) "romgi-bio ($ciBranch)" else "romgi-bio"

        // Builds pkg2zip (vendored at src/main/cpp/pkg2zip) into
        // src/main/jniLibs/<abi>/libpkg2zip.so — see src/main/cpp/CMakeLists.txt.
        externalNativeBuild {
            cmake {
                targets += "pkg2zip_bin"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        getByName("debug") {
            // Fixed keystore committed to the repo (not a secret — it's the
            // conventional Android debug key). Without this, "debug" falls
            // back to AGP's implicit ~/.android/debug.keystore, which
            // GitHub Actions' ephemeral runners regenerate from scratch on
            // every run — signing each release build with a different key
            // and forcing an uninstall/reinstall on every update.
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // Release ships arm64 only — every supported device is arm64-v8a,
            // and dropping x86/armv7 keeps the APK ~40 MB smaller.
            ndk {
                abiFilters += listOf("arm64-v8a")
            }
        }
        debug {
            // Debug also bundles x86_64 so we can run on the Windows
            // emulator (where qemu2 can only run x86 guests on x86 hosts).
            ndk {
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
    }

    packaging {
        // libtorrent4j's sub-jars contain duplicate licence files;
        // exclude them so the resource merger doesn't fail.
        resources {
            excludes += listOf(
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/AL2.0",
                "META-INF/LGPL2.1"
            )
        }
        // libtorrent4j's loader uses System.loadLibrary which needs the
        // .so extracted from the APK. The newer "compressed in-APK" mode
        // (default for release) breaks that load with
        // UnsatisfiedLinkError. Force the older extract-on-install mode.
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // libtorrent4j: torrent runtime. Maintained fork/successor of
    // jlibtorrent by the same author, wrapping libtorrent 2.x. Used
    // by LibreTorrent and most current Android torrent clients.
    // Verify before bumping at:
    //   https://central.sonatype.com/artifact/org.libtorrent4j/libtorrent4j
    val libtorrent4jVersion = "2.1.0-32"
    implementation("org.libtorrent4j:libtorrent4j:$libtorrent4jVersion")
    implementation("org.libtorrent4j:libtorrent4j-android-arm64:$libtorrent4jVersion")
    // Only included in debug APKs so emulator testing on x86 hosts works.
    debugImplementation("org.libtorrent4j:libtorrent4j-android-x86_64:$libtorrent4jVersion")

    // Apache Commons Compress: 7z extraction for disc-based ROM archives.
    implementation("org.apache.commons:commons-compress:1.27.1")
    // XZ (LZMA2) decoder — required by commons-compress for 7z extraction.
    implementation("org.tukaani:xz:1.10")
}
