// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "AsyncProcess",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "AsyncProcess",
            targets: ["AsyncProcess"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.0.1"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
    ],
    targets: [
        .target(name: "CProcessSpawnSync"),
        .target(
          name: "ProcessSpawnSync",
          dependencies: [
            "CProcessSpawnSync",
            .product(name: "Atomics", package: "swift-atomics"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
          ]
        ),
        .target(
          name: "AsyncProcess",
          dependencies: [
            "ProcessSpawnSync",
            .product(name: "Atomics", package: "swift-atomics"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "DequeModule", package: "swift-collections"),
            .product(name: "SystemPackage", package: "swift-system"),
          ]
        ),
        .testTarget(
          name: "AsyncProcessTests",
          dependencies: [
            "AsyncProcess",
            .product(name: "Atomics", package: "swift-atomics"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
          ]
        ),
    ]
)
