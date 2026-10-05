pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "MusicSyncPorts"
include(":core", ":desktop")
if (providers.gradleProperty("withAndroid").orNull != "false") include(":android")
