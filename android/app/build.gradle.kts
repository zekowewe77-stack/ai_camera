
plugins {
    id "com.android.application"
    id "org.jetbrains.kotlin.android"
    id "dev.flutter.flutter-gradle-plugin"
}

android {
    namespace "com.example.ai_camera_pro_2027"
    compileSdk flutter.compileSdkVersion
    ndkVersion flutter.ndkVersion

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId "com.example.ai_camera_pro_2027"
        minSdk 23
        targetSdk flutter.targetSdkVersion
        versionCode 1
        versionName "1.0.0"
    }
}

flutter {
    source "../.."
}
