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
// Force all plugin subprojects to compile against SDK 36.
// Some plugins (e.g. file_picker 8.x) ship with compileSdk=34 hardcoded
// in their own build.gradle, which fails the AAR metadata check when a
// transitive dependency (flutter_plugin_android_lifecycle) requires 36.
// This override ensures every Android library/application module in the
// build uses 36, matching the app's compileSdk.
//
// IMPORTANT: the afterEvaluate callback MUST be registered in the SAME
// subprojects block as evaluationDependsOn, and BEFORE it. If they're
// in separate blocks, evaluationDependsOn eagerly evaluates :app (and
// all the plugins it depends on), and the subsequent afterEvaluate
// call throws 'Cannot run Project.afterEvaluate when the project is
// already evaluated'.
subprojects {
    afterEvaluate {
        // Use the public API DSL interfaces (com.android.build.api.dsl.*).
        // The com.android.build.gradle.LibraryExtension / AppExtension
        // classes are deprecated internal ones that don't expose
        // compileSdk in newer AGP versions.
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.api.dsl.LibraryExtension) {
            androidExt.compileSdk = 36
        } else if (androidExt is com.android.build.api.dsl.ApplicationExtension) {
            androidExt.compileSdk = 36
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
