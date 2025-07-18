import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget
import org.jetbrains.kotlin.gradle.targets.native.tasks.KotlinNativeTest
import org.gradle.api.tasks.testing.logging.TestExceptionFormat

plugins {
    kotlin(PluginsDeps.multiplatform)
    id(PluginsDeps.mavenPublish)
    id(PluginsDeps.signing)
    id(PluginsDeps.node) version Versions.nodePlugin
    id(PluginsDeps.taskTree) version Versions.taskTreePlugin
    id(PluginsDeps.dokka)
}

val sonatypeSnapshots = "https://s01.oss.sonatype.org/content/repositories/snapshots/"
val sonatypePassword: String? by project
val sonatypeUsername: String? by project
val sonatypePasswordEnv: String? = System.getenv("SONATYPE_PASSWORD")
val sonatypeUsernameEnv: String? = System.getenv("SONATYPE_USERNAME")

repositories {
    mavenCentral()
    maven { url = uri("https://oss.sonatype.org/content/repositories/snapshots") }
}

group = ReleaseInfo.group
version = ReleaseInfo.bindingsVersion

val ideaActive = isInIdea()
println("Idea active: $ideaActive")

kotlin {
    jvm()
    val projectRef = project

    sourceSets.all {
        languageSettings.optIn("kotlin.concurrent.ExperimentalAtomicApi")
    }

    runningOnLinuxx86_64 {
        linuxX64 {
            compilations.getByName("main") {
                val libwrapperCinterop by cinterops.creating {
                    defFile(projectRef.file("src/nativeInterop/cinterop/libwrapper.def"))
                }
            }
            binaries { staticLib {} }
        }
    }

    targets.withType<KotlinNativeTarget>().configureEach {
        compilations.all {
            kotlinOptions.freeCompilerArgs += listOf(
                "-opt-in=kotlinx.cinterop.ExperimentalForeignApi",
                "-opt-in=kotlin.concurrent.ExperimentalAtomicApi"
            )
        }

        targets.withType<KotlinNativeTarget>().configureEach {

            //  pass library + search-path + its runtime deps to the linker
            binaries.all {
                linkerOpts(
                    "-L${openabeBuildDir.get().asFile}/lib",
                    "-lopenabe_static",   // the lib we just built
                    "-lssl", "-lcrypto",  // OpenSSL (OpenABE depends on it)
                    "-pthread"
                )
            }
        }
    }

    sourceSets {
        val commonMain by getting {
//            languageSettings.optIn("kotlin.concurrent.ExperimentalAtomicApi")
            dependencies {
                implementation(kotlin(Deps.Common.stdLib))
                implementation(kotlin(Deps.Common.test))
            }
        }
        val commonTest by getting {
            languageSettings.optIn("kotlin.concurrent.ExperimentalAtomicApi")
            dependencies {
                implementation(kotlin(Deps.Common.test))
                implementation(kotlin(Deps.Common.testAnnotation))
                implementation(Deps.Common.coroutines)
            }
        }

        val nativeDependencies = independentDependencyBlock {}

        val nativeMain by creating {
            languageSettings.optIn("kotlin.concurrent.ExperimentalAtomicApi")
            dependsOn(commonMain)
            isRunningInIdea { kotlin.setSrcDirs(emptySet<String>()) }
            dependencies { nativeDependencies(this) }
        }

        val nativeTest by creating {
            languageSettings.optIn("kotlin.concurrent.ExperimentalAtomicApi")
            dependsOn(commonTest)
            isRunningInIdea { kotlin.setSrcDirs(emptySet<String>()) }
        }

        val linux64Bit = setOf("linuxX64")

        targets.withType<KotlinNativeTarget> {
            compilations["main"].defaultSourceSet {
                if (linux64Bit.contains(this@withType.name)) dependsOn(nativeMain)
            }
            compilations["test"].defaultSourceSet.dependsOn(nativeTest)
        }

        val jvmMain by getting {
            kotlin.srcDirs("src/jvmSpecific", "src/jvmMain/kotlin")
            dependencies {
                implementation(kotlin(Deps.Jvm.stdLib))
                implementation(kotlin(Deps.Jvm.test))
                implementation(kotlin(Deps.Jvm.testJUnit))
                implementation(Deps.Jvm.resourceLoader)
                implementation(Deps.Jvm.Delegated.jna)
                implementation("org.slf4j:slf4j-api:1.7.30")
            }
        }
        val jvmTest by getting {
            dependencies {
                implementation(kotlin(Deps.Jvm.test))
                implementation(kotlin(Deps.Jvm.testJUnit))
                implementation(kotlin(Deps.Jvm.reflection))
            }
        }

        runningOnLinuxx86_64 {
            val linuxX64Main by getting { isRunningInIdea { kotlin.srcDir("src/nativeMain/kotlin") } }
            val linuxX64Test by getting {
                dependsOn(nativeTest)
                isRunningInIdea { kotlin.srcDir("src/nativeTest/kotlin") }
            }
        }
    }
    sourceSets.all {
        languageSettings.optIn("kotlin.concurrent.ExperimentalAtomicApi")
    }
}

tasks.whenTaskAdded {
    if ("DebugUnitTest" in name || "ReleaseUnitTest" in name) enabled = false
}

tasks {
    create<Jar>("javadocJar") {
        dependsOn(dokkaHtml)
        archiveClassifier.set("javadoc")
        from(dokkaHtml.get().outputDirectory)
    }

    dokkaHtml { dokkaSourceSets {} }

    if (getHostOsName() == "linux" && getHostArchitecture() == "x86-64") {
        val jvmTest by getting(Test::class) {
            testLogging {
                events("PASSED", "FAILED", "SKIPPED")
                exceptionFormat = TestExceptionFormat.FULL
                showStandardStreams = true
                showStackTraces = true
            }
        }
        val linuxX64Test by getting(KotlinNativeTest::class) {
            testLogging {
                events("PASSED", "FAILED", "SKIPPED")
                exceptionFormat = TestExceptionFormat.FULL
                showStandardStreams = true
                showStackTraces = true
            }
        }
    }
}

allprojects {
    tasks.withType(JavaCompile::class).configureEach {
        sourceCompatibility = "1.8"
        targetCompatibility = "1.8"
    }
}

signing {
    isRequired = false
    sign(publishing.publications)
}

val openabeSrc      = projectDir.resolve("openabe")
val openabeBuildDir = layout.buildDirectory.dir("openabe")

// 1. configure + build static PIC library
val buildOpenAbe by tasks.register<Exec>("buildOpenAbe") {
    // mkdir -p build/openabe && cd it
    workingDir(openabeBuildDir.get().asFile)
    commandLine(
        "cmake",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        "-DCMAKE_BUILD_TYPE=Release",
        openabeSrc.absolutePath
    )
    // build target `openabe_static`
    doLast {
        exec {
            workingDir(openabeBuildDir.get().asFile)
            commandLine("cmake", "--build", ".", "--config", "Release", "--target", "openabe_static")
        }
    }
}

publishing {
    publications.withType(MavenPublication::class) {
        artifact(tasks["javadocJar"])
        pom {
            name.set("Kotlin Multiplatform Libopenabe Wrapper")
            description.set("Kotlin Multiplatform Libopenabe Wrapper")
            url.set("https://github.com/StefanoBerlato/kotlin-multiplatform-openabe")
            licenses {
                license {
                    name.set("The GNU Affero General Public License, Version 3.0")
                    url.set("https://www.gnu.org/licenses/agpl-3.0.en.html")
                }
            }
            developers {
                developer {
                    id.set("StefanoBerlato")
                    name.set("Stefano Berlato")
                    email.set("sb.berlatostefano@gmail.com")
                }
            }
            scm {
                url.set("https://github.com/StefanoBerlato/kotlin-multiplatform-openabe")
                connection.set("scm:git:git://github.com/StefanoBerlato/kotlin-multiplatform-openabe.git")
                developerConnection.set("scm:git:ssh://git@github.com:StefanoBerlato/kotlin-multiplatform-openabe.git")
            }
        }
    }

    repositories {
        maven {
            name = "snapshot"
            url = uri(sonatypeSnapshots)
            credentials {
                username = sonatypeUsername ?: sonatypeUsernameEnv ?: ""
                password = sonatypePassword ?: sonatypePasswordEnv ?: ""
            }
        }
    }
}
