plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "community.reel.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "community.reel.app"
        minSdk = 26
        targetSdk = 37
        // CI passes the run number, as the iOS build does, so both platforms count builds alike.
        val build = (project.findProperty("reel.build") as String?)?.toIntOrNull() ?: 1
        versionCode = build
        versionName = "0.1.$build"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed with the debug key unless CI provides a release key, so every build installs.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures { compose = true; buildConfig = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.coroutines.android)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.navigation.compose)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.ui)
    implementation(libs.media3.session)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.media3.ffmpeg)
    implementation(libs.tv.material)
    implementation(libs.coil.compose)
    implementation(libs.coil.network)
    implementation(libs.work.runtime)
    implementation(libs.glance.appwidget)
    implementation(libs.glance.material3)
    testImplementation(libs.junit)
}
