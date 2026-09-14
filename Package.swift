// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Shelf", targets: ["Shelf"]),
        .executable(name: "ShelfIconTool", targets: ["ShelfIconTool"])
    ],
    targets: [
        .target(
            name: "ShelfCore",
            path: "ShelfCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .target(
            name: "ShelfNative",
            path: "ShelfNative",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "Shelf",
            dependencies: ["ShelfCore", "ShelfNative"],
            path: "Shelf",
            exclude: [
                "Info.plist",
                "Resources"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "ShelfIconTool",
            dependencies: ["ShelfCore"],
            path: "Tools/IconTool",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "ShelfCoreTests",
            dependencies: ["ShelfCore"],
            path: "ShelfCoreTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ]),
                .linkedFramework("Testing")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
