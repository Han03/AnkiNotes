// swift-tools-version:5.9
//
//  备用：如果 Xcode 项目无法直接打开，可以用 Swift Package Manager 方式验证
//  代码编译。在 Xcode 中选择 File -> Open -> 目录 即可。
//  注意：Swift Package 不直接产生 iOS App，真正构建 iOS App 请用 AnkiNotes.xcodeproj
//

import PackageDescription

let package = Package(
    name: "AnkiNotes",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AnkiNotesCore", targets: ["AnkiNotesCore"])
    ],
    targets: [
        .target(
            name: "AnkiNotesCore",
            path: ".",
            exclude: [
                "AnkiNotes.xcodeproj",
                "Package.swift"
            ],
            sources: [
                "AnkiNotesApp.swift",
                "Models",
                "Services",
                "Views"
            ]
        )
    ]
)
