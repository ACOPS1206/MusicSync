plugins { kotlin("jvm"); kotlin("plugin.serialization") }
kotlin { jvmToolchain(17) }
dependencies {
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    api("org.bouncycastle:bctls-jdk18on:1.81")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.81")
    api("org.jmdns:jmdns:3.6.1")
    testImplementation(kotlin("test"))
}
tasks.test { useJUnitPlatform(); testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL } }
