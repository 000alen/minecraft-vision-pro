plugins {
    java
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

dependencies {
    implementation("com.google.code.gson:gson:2.11.0")
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testImplementation(project(":bridge-mock-host"))
}

tasks.test {
    useJUnitPlatform()
}

sourceSets {
    main {
        java {
            srcDirs(rootProject.file("minecraft/VivecraftMod/common/src/main/java/visioncraft/bridge"))
        }
    }
    test {
        java {
            srcDirs(rootProject.file("test/src/test/java"))
        }
    }
}

tasks.jar {
    archiveBaseName.set("visioncraft-bridge")
}
