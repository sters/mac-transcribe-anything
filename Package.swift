// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mac-transcribe-anything",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "transcribe",
            exclude: ["Info.plist"],
            linkerSettings: [
                // A bare executable has no bundle, so the usage descriptions TCC requires are
                // embedded into the binary's __info_plist section.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/transcribe/Info.plist",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
