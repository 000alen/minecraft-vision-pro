rootProject.name = "visioncraft"

include("bridge-lib")
include("bridge-mock-host")
include("bridge-test")

project(":bridge-lib").projectDir = file("bridge/java/lib")
project(":bridge-mock-host").projectDir = file("bridge/java/mock-host")
project(":bridge-test").projectDir = file("bridge/java/test-pattern-sender")
