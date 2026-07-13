// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "NotchDeckKit",
            path: "Sources/NotchDeckKit"
        ),
        .executableTarget(
            name: "NotchDeck",
            dependencies: ["NotchDeckKit"],
            path: "Sources/NotchDeck"
        ),
        // CLT-only environments lack XCTest/Testing, so checks are a plain
        // executable: `swift run NotchDeckChecks`.
        .executableTarget(
            name: "NotchDeckChecks",
            dependencies: ["NotchDeckKit"],
            path: "Sources/NotchDeckChecks"
        ),
    ]
)
