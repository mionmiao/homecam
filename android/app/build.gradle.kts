plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }

android {
    namespace = "com.homecam.camera"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.homecam.camera"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("io.socket:socket.io-client:2.1.2") { exclude(group = "org.json", module = "json") }
    implementation("org.webrtc:google-webrtc:1.0.32006")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
