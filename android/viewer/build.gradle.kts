import java.util.Properties

plugins {
    id("com.android.application")
}

// The same release key as the other two apps, kept outside the repository (see app/build.gradle.kts).
val signingDir = rootProject.file("../../Sideboard-签名")
val signing = signingDir.resolve("keystore.properties").takeIf { it.exists() }?.let { file ->
    Properties().apply { file.inputStream().use { load(it) } }
}

android {
    namespace = "app.sideboard.viewer"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "app.sideboard.viewer"
        // Android 8, like the Link app it talks to.
        minSdk = 26
        targetSdk = 36
        versionCode = 4
        versionName = "0.4"
    }

    signingConfigs {
        if (signing != null) {
            create("release") {
                storeFile = signingDir.resolve(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    androidResources {
        localeFilters += listOf("en", "zh-rCN")
    }
}
