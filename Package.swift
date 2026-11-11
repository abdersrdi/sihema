// swift-tools-version:5.9
import PackageDescription

// SihemaCore is plain Swift with no Apple-only imports, so its tests also run on Linux CI runners.
let package = Package(
    name: "Sihema",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SihemaCore", targets: ["SihemaCore"])
    ],
    targets: [
        .target(name: "SihemaCore", path: "Sources/SihemaCore"),
        .executableTarget(name: "SihemaBench", dependencies: ["SihemaCore"], path: "Sources/SihemaBench"),
        .executableTarget(name: "SihemaCheck", dependencies: ["SihemaCore"], path: "Sources/SihemaCheck"),
        .testTarget(name: "SihemaCoreTests", dependencies: ["SihemaCore"], path: "Tests/SihemaCoreTests")
    ]
)
