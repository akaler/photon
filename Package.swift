// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "photon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "photon",
            targets: ["photon"]
        ),
        .executable(
            name: "photon-overlay",
            targets: ["photon-overlay"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "PhotonCore"
        ),
        .executableTarget(
            name: "photon",
            dependencies: ["PhotonCore"]
        ),
        .executableTarget(
            name: "photon-overlay",
            dependencies: ["PhotonCore"]
        ),
        .testTarget(
            name: "photonTests",
            dependencies: [
                .product(name: "Testing", package: "swift-testing"),
                "PhotonCore",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
