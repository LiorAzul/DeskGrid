// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DeskGrid",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DeskGrid",
            exclude: ["Info.plist"],
            resources: [.copy("AppIcon.png")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/DeskGrid/Info.plist"])
            ]
        ),
    ]
)
