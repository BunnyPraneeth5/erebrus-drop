import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun hasSigningBlock(prefix: String): Boolean {
    return listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .all { !keystoreProperties.getProperty("$prefix.$it").isNullOrBlank() }
}

val hasPlaystoreSigning = hasSigningBlock("playstore")
val hasDappstoreSigning = hasSigningBlock("dappstore")

val isReleaseBuild = gradle.startParameter.taskNames
    .any { it.contains("Release", ignoreCase = true) }

val requestedFlavor = gradle.startParameter.taskNames
    .firstOrNull { task ->
        task.contains("playstore", ignoreCase = true) ||
            task.contains("dappstore", ignoreCase = true)
    }
    ?.let { task ->
        when {
            task.contains("dappstore", ignoreCase = true) -> "dappstore"
            task.contains("playstore", ignoreCase = true) -> "playstore"
            else -> null
        }
    }

if (isReleaseBuild) {
    when (requestedFlavor) {
        "playstore" -> {
            if (!hasPlaystoreSigning) {
                error(
                    "Play Store release signing is not configured. Fill in the " +
                        "playstore.* values in android/key.properties, then build again."
                )
            }
        }
        "dappstore" -> {
            if (!hasDappstoreSigning) {
                error(
                    "dApp Store release signing is not configured. Fill in the " +
                        "dappstore.* values in android/key.properties, then build again."
                )
            }
        }
        else -> {
            error(
                "Release builds require an explicit flavor. Use --flavor playstore " +
                    "for Google Play or --flavor dappstore for the Solana dApp Store."
            )
        }
    }
}

android {
    namespace = "com.erebrus.drop"
    // solana_mobile_client transitives require compileSdk >= 33.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.erebrus.drop"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "store"
    productFlavors {
        create("playstore") {
            dimension = "store"
        }
        create("dappstore") {
            dimension = "store"
        }
    }

    signingConfigs {
        create("playstoreRelease") {
            enableV2Signing = true
            enableV3Signing = true
            if (hasPlaystoreSigning) {
                keyAlias = keystoreProperties.getProperty("playstore.keyAlias")
                keyPassword = keystoreProperties.getProperty("playstore.keyPassword")
                storeFile = file(keystoreProperties.getProperty("playstore.storeFile"))
                storePassword = keystoreProperties.getProperty("playstore.storePassword")
            }
        }
        create("dappstoreRelease") {
            enableV2Signing = true
            enableV3Signing = true
            if (hasDappstoreSigning) {
                keyAlias = keystoreProperties.getProperty("dappstore.keyAlias")
                keyPassword = keystoreProperties.getProperty("dappstore.keyPassword")
                storeFile = file(keystoreProperties.getProperty("dappstore.storeFile"))
                storePassword = keystoreProperties.getProperty("dappstore.storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Signing is assigned per flavor below. Flutter release builds do not
            // enable code shrinking; keep resource shrinking off as well.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    androidComponents {
        onVariants { variant ->
            val flavorName = variant.productFlavors
                .firstOrNull { it.first == "store" }
                ?.second

            if (variant.buildType == "release") {
                // Releases ship arm64 only (Flutter is built with
                // --target-platform android-arm64). Plugins such as FFmpegKit
                // bundle extra ABIs; left in, they bloat the APK and make Play
                // offer the app to 32-bit/x86 devices that have no
                // libflutter.so for their ABI.
                variant.packaging.jniLibs.excludes.addAll(
                    listOf("lib/armeabi-v7a/**", "lib/x86_64/**", "lib/x86/**"),
                )
                when (flavorName) {
                    "playstore" -> {
                        variant.signingConfig.setConfig(signingConfigs.getByName("playstoreRelease"))
                    }
                    "dappstore" -> {
                        variant.signingConfig.setConfig(signingConfigs.getByName("dappstoreRelease"))
                    }
                }
            }
        }
    }
}

// Default debug builds to playstore so `flutter run` works without --flavor.
androidComponents {
    beforeVariants { variantBuilder ->
        val flavorName = variantBuilder.productFlavors
            .firstOrNull { it.first == "store" }
            ?.second
        if (variantBuilder.buildType == "debug" && flavorName == "dappstore") {
            variantBuilder.enable = false
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

dependencies {
    implementation("com.solanamobile:mobile-wallet-adapter-clientlib:1.1.0")
    implementation("androidx.camera:camera-camera2:1.5.3")
    implementation("androidx.camera:camera-lifecycle:1.5.3")
    implementation("androidx.camera:camera-view:1.5.3")
    implementation("com.google.zxing:core:3.5.3")
}