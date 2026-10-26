allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.buildDir = File("../build")

// Host-only compatibility for the pinned plugins' legacy namespace detection.
// Values match their Android manifests and Java/plugin package declarations.
val legacyJniNamespaces = mapOf(
    "jni" to "com.github.dart_lang.jni",
    "jni_flutter" to "com.github.dart_lang.jni_flutter"
)

subprojects {
    project.buildDir = File(rootProject.buildDir, project.name)
    legacyJniNamespaces[name]?.let { expected ->
        pluginManager.withPlugin("com.android.library") {
            val android = project.extensions.getByName("android")
            val current = android.javaClass.getMethod("getNamespace")
                .invoke(android) as String?
            if (current.isNullOrBlank()) {
                android.javaClass.getMethod("setNamespace", String::class.java)
                    .invoke(android, expected)
            } else {
                check(current == expected) { "Unexpected JNI namespace for ${project.path}" }
            }
        }
    }
}

// Register all plugin callbacks before app evaluation can configure dependencies.
subprojects {
    project.evaluationDependsOn(":app")
}
