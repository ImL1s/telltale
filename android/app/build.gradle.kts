import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, if a keystore has been provided.
//
// `android/key.properties` is gitignored, as are `*.jks` and `*.keystore`, so
// the credentials never enter this repository. When the file is absent the
// build still works — it falls back to the debug key — but it says so loudly
// rather than producing an artifact that looks shippable and is not. An APK
// signed with the debug key cannot be updated by a Play-signed one later, so
// discovering this after publishing is expensive.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.cbstudio.telltale"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cbstudio.telltale"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    flavorDimensions += "environment"
    productFlavors {
        create("field") {
            dimension = "environment"
        }
        create("rig") {
            dimension = "environment"
            // The no-car rig must coexist with a debug or release field app.
            // Only this explicit flavor gets the simulated-evidence identity;
            // a normal debug build remains usable against a physical adapter.
            applicationIdSuffix = ".rig"
            versionNameSuffix = "-rig"
        }
        create("wear") {
            dimension = "environment"
            // Same applicationId as the phone app on purpose: Google Play
            // ships watch and phone artifacts of one listing under one id,
            // each declaring its form factor. The manifest overlay in
            // src/wear/ adds the watch feature and standalone declaration.
            versionNameSuffix = "-wear"
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Debug-signed, and refused below. A warning is not a gate,
                // and the warning this replaced produced a debug-signed AAB
                // that looks shippable, can never be a valid update for a
                // production signing lineage, and is indistinguishable from
                // the real thing once it leaves the machine that built it.
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

// Release artifacts must not be debug-signed.
//
// This blocks *every* release packaging path, including flavor-qualified tasks
// such as `assembleFieldRelease` and `bundleFieldRelease`. An earlier version
// claimed local release runs still worked, but the gate correctly refused the
// packaging task, so the documentation contradicted the behaviour.
//
// Rather than carve out an exception that would also let a distributable APK
// through, the local case is served by the same explicit override:
//
//     flutter run --release --flavor field -PallowUnsignedRelease=true
//
// The point is that building something debug-signed has to be a choice
// somebody made, not a default they did not notice.
if (!hasReleaseKeystore) {
    // Matched by shape rather than by an enumerated list of four names, which
    // was brittle: any release packaging task whose leaf name happened not to
    // be in the set walked straight past.
    //
    // Scoped to this module. Unscoped it also matched every dependency's
    // `bundleLibCompileToJarRelease`, which package nothing shippable and
    // turned the refusal message into thirty lines of noise.
    fun isReleasePackaging(name: String): Boolean {
        val prefixes = listOf("assemble", "bundle", "package", "publish")
        return name.endsWith("Release") &&
            prefixes.any { name.startsWith(it) } &&
            !name.startsWith("bundleLib")
    }

    val optedOut =
        (project.findProperty("allowUnsignedRelease") as String?)?.toBoolean() == true

    gradle.taskGraph.whenReady {
        val requested = allTasks
            .filter { it.project == project && isReleasePackaging(it.name) }
            .map { it.name }
            .distinct()
        if (requested.isNotEmpty() && !optedOut) {
            throw GradleException(
                "\n" +
                    "  ============================================================\n" +
                    "   Refusing to build " + requested.joinToString(", ") + ".\n" +
                    "\n" +
                    "   android/key.properties is missing, so this artifact\n" +
                    "   would be signed with the DEBUG key. It would install\n" +
                    "   and run, and it could never be a valid update for the\n" +
                    "   production signing lineage.\n" +
                    "\n" +
                    "   Create android/key.properties with storeFile,\n" +
                    "   storePassword, keyAlias and keyPassword.\n" +
                    "\n" +
                    "   For a local release run, or to build one anyway:\n" +
                    "     -PallowUnsignedRelease=true\n" +
                    "  ============================================================\n"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
