allprojects {

    repositories {

        google()

        mavenCentral()

        maven {

            url =
                uri(
                    "https://storage.googleapis.com/download.flutter.io"
                )
        }
    }
}

rootProject.buildDir = File("../build")

subprojects {
    project.buildDir = File(rootProject.buildDir, project.name)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}
