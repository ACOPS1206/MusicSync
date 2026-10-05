plugins { id("com.android.application"); kotlin("android"); id("org.jetbrains.kotlin.plugin.compose") }
android {
    namespace = "dev.musicsync.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "dev.musicsync.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 13
        versionName = "0.9.1"
    }
    sourceSets["main"].java.srcDir("../ui")
    buildFeatures { compose = true; buildConfig = true }
    packaging { resources { excludes += setOf("META-INF/versions/**", "META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA"); merges += "META-INF/services/**" } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    // The debug certificate lets users install the CI APK directly; release uses their own signing.
    buildTypes { getByName("release") { isMinifyEnabled = false } }
}
dependencies {
    implementation(project(":core"))
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.compose.ui:ui:1.9.4")
    implementation("androidx.compose.foundation:foundation:1.9.4")
    implementation("androidx.compose.material3:material3:1.4.0-alpha18")
}
