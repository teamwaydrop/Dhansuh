plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

import java.io.FileInputStream
import java.util.Properties

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Load secrets from the Flutter project's .env file (never hardcode keys here).
// This mirrors the same .env that flutter_dotenv reads at runtime, so there is a
// single source of truth for the Ola Maps key instead of a duplicated literal.
val dotEnvFile = rootProject.file("../.env")
val dotEnvProperties = Properties()
if (dotEnvFile.exists()) {
    dotEnvFile.forEachLine { line ->
        val trimmed = line.trim()
        if (trimmed.isNotEmpty() && !trimmed.startsWith("#") && trimmed.contains("=")) {
            val separatorIndex = trimmed.indexOf("=")
            val key = trimmed.substring(0, separatorIndex).trim()
            val value = trimmed.substring(separatorIndex + 1).trim()
            dotEnvProperties.setProperty(key, value)
        }
    }
}
val olaMapsApiKey = dotEnvProperties.getProperty("OLA_MAPS_API_KEY") ?: ""


repositories {

    flatDir {

        dirs(
            "libs"
        )
    }

    google()

    mavenCentral()
}
android {

    namespace =
        "com.waydrop.app"

    compileSdk =
        36

    ndkVersion =
        flutter.ndkVersion

   signingConfigs {
        create("release") {
            val storeFilePath = keystoreProperties["storeFile"] as String?
            if (storeFilePath != null) {
                storeFile = file(storeFilePath)
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    defaultConfig {

        applicationId =
            "com.waydrop.app"

        minSdk =
            24

        targetSdk =
            36

        versionCode =
            flutter.versionCode

        versionName =
            flutter.versionName
        buildConfigField(
    "String",
    "OLA_MAPS_API_KEY",
    "\"$olaMapsApiKey\""
)
    }
   
buildTypes {

    release {

        isMinifyEnabled = true

        isShrinkResources = true
        isDebuggable = false

        proguardFiles(
            getDefaultProguardFile("proguard-android-optimize.txt"),
            "proguard-rules.pro"
        )

        signingConfig =
            signingConfigs.getByName(
                "release"
            )
    }
}

    compileOptions {
        isCoreLibraryDesugaringEnabled = true

        sourceCompatibility =
            JavaVersion.VERSION_17

        targetCompatibility =
            JavaVersion.VERSION_17
    }

    kotlinOptions {

        jvmTarget = "17"
    }

    buildFeatures {

        buildConfig = true
    }

    packaging {

        resources {

            excludes +=
                "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    implementation(
        "androidx.appcompat:appcompat:1.7.0"
    )

    implementation(
        "com.google.android.material:material:1.11.0"
    )

    implementation(
        "androidx.constraintlayout:constraintlayout:2.1.4"
    )

    implementation(
        "androidx.lifecycle:lifecycle-runtime-ktx:2.7.0"
    )

    implementation(
        "com.google.android.gms:play-services-location:21.2.0"
    )

    implementation(platform("com.google.firebase:firebase-bom:34.14.0"))
    implementation("com.google.firebase:firebase-analytics")
}
flutter {

    source = "../.."
}