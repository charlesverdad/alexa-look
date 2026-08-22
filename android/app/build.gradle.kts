plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.charlesverdad.alexa_look"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.charlesverdad.alexa_look"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ffmpeg_kit_flutter requires API 24+.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ABIs we ship libcamraw.so (RAW/DNG decoding, see native/) for.
        // Covers essentially all real Android devices; excludes the rarely
        // used 32-bit x86 and armeabi.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    // Builds native/CMakeLists.txt (vendored LibRaw + the camraw wrapper)
    // into libcamraw.so, loaded at runtime via dart:ffi from
    // lib/core/raw_decoder.dart. See native/libraw/VENDORING.md.
    //
    // Deliberately not pinning externalNativeBuild.cmake.version here: AGP
    // auto-selects whichever CMake package already installed in the SDK
    // satisfies native/CMakeLists.txt's `cmake_minimum_required` (3.18), so
    // this doesn't depend on exactly which CMake versions a given CI
    // runner image happens to bundle (subject to drift over time) and
    // avoids triggering an SDK-manager download for a specific version
    // that may not be present.
    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
