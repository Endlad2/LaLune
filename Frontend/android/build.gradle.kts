// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Root build.gradle.kts.
//
// Репозитории заданы здесь для всех проектов.
// Порядок: mavenLocal → google → mavenCentral → gradlePluginPortal.
// Это спасает от падений с "github.com: No address associated with hostname",
// которые возникают, когда gradlePluginPortal делает redirect на GitHub Releases.

allprojects {
    repositories {
        mavenLocal()
        google()
        mavenCentral()
        // Fallback, но с явным ограничением: не пытаться тянуть
        // kotlin-compiler-embeddable отсюда (это как раз вызывает redirect).
        gradlePluginPortal {
            content {
                excludeGroup("org.jetbrains.kotlin")
            }
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
