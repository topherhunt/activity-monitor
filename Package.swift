// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dayline",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Dayline",
            path: "Sources/Dayline",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "DaylineTests",
            dependencies: ["Dayline"],
            path: "Tests/DaylineTests"
        ),
    ]
)
