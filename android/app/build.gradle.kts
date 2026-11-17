plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }

android { namespace = "com.homecam.camera"; compileSdk = 35
    defaultConfig { applicationId = "com.homecam.camera"; minSdk = 26; targetSdk = 35; versionCode = 1; versionName = "0.1.0" }
}
dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("io.socket:socket.io-client:2.1.0") { exclude(group = "org.json", module = "json") }
    implementation("org.webrtc:google-webrtc:1.0.32006")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
