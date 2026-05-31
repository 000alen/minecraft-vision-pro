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
}

tasks.test {
    useJUnitPlatform()
}

sourceSets {
    main {
        java {
            srcDirs("../bridge/java")
        }
    }
    test {
        java {
            srcDirs("../test/src/test/java")
        }
    }
}

tasks.jar {
    archiveBaseName.set("visioncraft-bridge")
}
