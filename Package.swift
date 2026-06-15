// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerfectNIO",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "PerfectNIOExe", targets: ["PerfectNIOExe"]),
        .library(name: "PerfectNIO", targets: ["PerfectNIO"]),
        .library(name: "PerfectNIOMustache", targets: ["PerfectNIOMustache"]),
        // PerfectNIOCRUD disabled — uses removed .async{} API; restore in Phase 7
        // .library(name: "PerfectNIOCRUD", targets: ["PerfectNIOCRUD"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.21.0"),
        // Optional target dependencies — these libraries are pre-Swift-6 and compile in their own language mode
        .package(url: "https://github.com/PerfectlySoft/Perfect-Mustache.git", from: "4.0.0"),
        .package(url: "https://github.com/PerfectlySoft/Perfect-CRUD.git", from: "2.0.0"),
        // Test dependency — PerfectCURL was already fixed in this resurrection effort
        .package(path: "../Perfect-CURL"),
    ],
    targets: [
        // Local system library wrapping libz — replaces PerfectCZlib
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib",
            providers: [
                .brew(["zlib"]),
                .apt(["zlib1g-dev"]),
            ]
        ),
        .executableTarget(
            name: "PerfectNIOExe",
            dependencies: ["PerfectNIO"]
        ),
        .target(
            name: "PerfectNIO",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                "CZlib",
            ]
        ),
        // Optional: Mustache template support
        .target(
            name: "PerfectNIOMustache",
            dependencies: [
                "PerfectNIO",
                .product(name: "PerfectMustache", package: "Perfect-Mustache"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        // PerfectNIOCRUD disabled — uses removed .async{} API; restore in Phase 7
        // .target(
        //     name: "PerfectNIOCRUD",
        //     dependencies: [
        //         "PerfectNIO",
        //         .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
        //         .product(name: "NIO", package: "swift-nio"),
        //     ]
        // ),
        // PerfectNIOTests is kept as historical reference but not compiled —
        // it imports removed packages (PerfectCRUD, PerfectLib, PerfectCURL) and
        // uses the old EventLoopFuture-based API that Phase 2+3 replaced.
        // Restore this target in Phase 7 when the test suite is rewritten.
        // .testTarget(
        //     name: "PerfectNIOTests",
        //     dependencies: [
        //         "PerfectNIO",
        //         .product(name: "PerfectCURL", package: "Perfect-CURL"),
        //     ]
        // ),
        // New smoke tests — no external deps, uses URLSession for HTTP.
        // Validates Phase 2+3 async route chain and HTTPOutput.nextChunk() end-to-end.
        .testTarget(
            name: "PerfectNIOSmokeTests",
            dependencies: [
                "PerfectNIO",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
