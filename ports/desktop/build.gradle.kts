import org.jetbrains.compose.desktop.application.dsl.TargetFormat
plugins { kotlin("jvm"); id("org.jetbrains.compose"); id("org.jetbrains.kotlin.plugin.compose") }
kotlin { jvmToolchain(17); sourceSets.main { kotlin.srcDir("../ui") } }
dependencies {
    implementation(project(":core"))
    implementation(compose.desktop.currentOs)
    implementation("org.jetbrains.compose.material3:material3:1.9.0-alpha04")
    implementation("net.java.dev.jna:jna:5.17.0")
}
compose.desktop {
    application {
        mainClass = "dev.musicsync.desktop.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Deb, TargetFormat.Rpm)
            packageName = "MusicSync"
            packageVersion = "0.9.3"
            description = "MusicSync LAN synchronized speakers"
            vendor = "ACOPS1206"
            modules("java.desktop", "java.logging", "java.naming", "jdk.crypto.ec", "jdk.unsupported")
            windows { menu = true; shortcut = true; upgradeUuid = "b8e8ad20-b1b4-4d22-815f-4a77fe2eb230" }
        }
    }
}
tasks.register<JavaExec>("interop") {
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("dev.musicsync.desktop.InteropKt")
    args(providers.gradleProperty("interopPort").orElse("49555").get())
}
