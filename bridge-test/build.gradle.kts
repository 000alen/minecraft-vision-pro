plugins {
    application
    java
}

application {
    mainClass.set("visioncraft.bridge.test.FakeStereoFrameSender")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

dependencies {
    implementation(project(":bridge-lib"))
}

sourceSets {
    main {
        java {
            srcDirs("src/main/java")
        }
    }
}
