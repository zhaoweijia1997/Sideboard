import java.util.Properties

plugins {
    id("com.android.application")
}

// The release key lives outside the repository (../../Sideboard-签名 from here), so it can
// never be committed. Without it, release builds fall back to the debug key: fine for trying
// it out, but such a build can't update a copy installed by the published Sideboard.
val signingDir = rootProject.file("../../Sideboard-签名")
val signing = signingDir.resolve("keystore.properties").takeIf { it.exists() }?.let { file ->
    Properties().apply { file.inputStream().use { load(it) } }
}

android {
    namespace = "com.weijiazhao.sideboard"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "com.weijiazhao.sideboard"
        // Android 8: older TVs and boxes are still around.
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
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
        localeFilters += listOf("en", "zh-rCN", "zh-rTW", "ja", "ru", "es", "hi")
    }
}
