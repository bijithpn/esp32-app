allprojects {
    repositories {
        google()
        mavenCentral()
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

// Lint-vital runs on release builds and crashes inside third-party plugins
// (e.g. image_picker_android) when the lint engine hits a newer-JDK API.
// It is not needed for producing the APK, so skip it.
gradle.projectsEvaluated {
    rootProject.allprojects {
        tasks.matching { it.name.startsWith("lintVital") }.configureEach {
            enabled = false
        }
    }
}
