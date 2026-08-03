import groovy.json.JsonSlurper

val rustlsPlatformVerifierSupport = run {
    val manifest = rootProject.file("../../rust/Cargo.toml")
    val metadataJson = providers.exec {
        commandLine(
            "cargo",
            "metadata",
            "--format-version",
            "1",
            "--filter-platform",
            "aarch64-linux-android",
            "--manifest-path",
            manifest.absolutePath,
        )
    }.standardOutput.asText.get()
    val metadata = JsonSlurper().parseText(metadataJson) as Map<*, *>
    val packages = metadata["packages"] as List<*>
    val supportPackage = packages
        .map { it as Map<*, *> }
        .single { it["name"] == "rustls-platform-verifier-android" }
    Pair(
        file(supportPackage["manifest_path"] as String).parentFile.resolve("maven"),
        supportPackage["version"] as String,
    )
}
rootProject.extra["rustlsPlatformVerifierVersion"] = rustlsPlatformVerifierSupport.second

allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri(rustlsPlatformVerifierSupport.first)
            metadataSources { artifact() }
            content { includeGroup("rustls") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    if (project.name == "file_picker") {
        project.pluginManager.apply("org.jetbrains.kotlin.android")
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
