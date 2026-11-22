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
        // 只打 arm64 WebRTC 库：4 ABI 时原生库占 44MB，arm64 单库仅 11MB
        ndk { abiFilters += "arm64-v8a" }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        // CI 出的是 debug 包，但关闭 debuggable，避免 ADB run-as 直接读取应用沙盒
        getByName("debug") { isDebuggable = false }
    }
}
dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("io.socket:socket.io-client:2.1.2") { exclude(group = "org.json", module = "json") }
    implementation("io.github.webrtc-sdk:android:137.7151.04")  // LiveKit 维护的 libwebrtc，Maven Central
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
