allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Align Gradle build output with Flutter CLI expectations at mobile/build/
val flutterBuildOutput = rootProject.layout.projectDirectory.dir("../build")
rootProject.layout.buildDirectory.set(flutterBuildOutput)

subprojects {
    project.layout.buildDirectory.set(flutterBuildOutput.dir(project.name))
    if (project.name != "app") {
        project.evaluationDependsOn(":app")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
