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
        // ObjC-only shield: Swift cannot catch ObjC exceptions, and QuickLook's
        // QLScrollController throws one from its scroller teardown during
        // scroller-style switches (crashes the app mid wheel-scroll). This
        // target swizzles a @try/@catch around exactly that method.
        .target(name: "ConspectusShield", publicHeadersPath: "include"),
        .executableTarget(
            name: "conspectus",
            dependencies: ["SwiftTerm", "ConspectusCore", "ConspectusShield"]
        ),
        .testTarget(
            name: "ConspectusCoreTests",
            dependencies: ["ConspectusCore"]
        ),
    ]
)
