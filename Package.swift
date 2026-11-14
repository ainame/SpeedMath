// swift-tools-version:6.4
import PackageDescription

let package = Package(
  name: "SpeedMath",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(url: "https://github.com/elementary-swift/elementary-ui.git", from: "0.9.1"),
    .package(url: "https://github.com/ainame/elementary-router.git", branch: "main"),
    .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.62.0"),
  ],
  targets: [
    .target(name: "ProtocolModels"),
    .target(name: "SessionLogic", dependencies: ["ProtocolModels"]),
    .testTarget(name: "SessionLogicTests", dependencies: ["SessionLogic", "ProtocolModels"]),
    .target(
      name: "RemoteProtocol",
      dependencies: ["ProtocolModels", .product(name: "JavaScriptKit", package: "JavaScriptKit")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "WebApp",
      dependencies: [
        "SessionLogic",
        "ProtocolModels",
        "RemoteProtocol",
        .product(name: "ElementaryUI", package: "elementary-ui"),
        .product(name: "ElementaryRouter", package: "elementary-router"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ],
    )
  ]
)
