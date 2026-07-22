// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "conspectus",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // Pure, unit-testable helpers (start-dir resolution, palettes, icon
        // mapping, listing order) — no SwiftTerm dependency.
        .target(name: "ConspectusCore"),
        .executableTarget(
            name: "conspectus",
            dependencies: ["SwiftTerm", "ConspectusCore"]
        ),
        .testTarget(
            name: "ConspectusCoreTests",
            dependencies: ["ConspectusCore"]
        ),
    ]
)
