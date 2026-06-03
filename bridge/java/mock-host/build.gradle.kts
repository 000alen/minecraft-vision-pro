plugins {
    application
    java
}

application {
    mainClass.set("visioncraft.bridge.mock.MockVisionCraftHost")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

dependencies {
    implementation(project(":bridge-lib"))
    implementation("com.google.code.gson:gson:2.11.0")
}

sourceSets {
    main {
        java {
            srcDirs("src/main/java")
        }
    }
}
