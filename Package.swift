// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneAct",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OneAct", targets: ["OneAct"])
    ],
    targets: [
        .executableTarget(
            name: "OneAct",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
