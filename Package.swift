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
    // The remote control's client logic (RemoteLink), free of JavaScriptKit so it runs in `swift test`.
    .target(name: "RemoteClient", dependencies: ["ProtocolModels"]),
    .testTarget(name: "RemoteClientTests", dependencies: ["RemoteClient", "ProtocolModels"]),
    .testTarget(name: "SessionLogicTests", dependencies: ["SessionLogic", "ProtocolModels"]),
    // Typed browser APIs (BridgeJS bindings) and the small Swift wrappers the app uses.
    .target(
      name: "BrowserAPI",
      dependencies: ["ProtocolModels", .product(name: "JavaScriptKit", package: "JavaScriptKit")],
      swiftSettings: [.swiftLanguageMode(.v5), .enableExperimentalFeature("Extern")],
      plugins: [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
    ),
    .target(
      name: "RemoteProtocol",
      dependencies: [
        "ProtocolModels", "RemoteClient", "BrowserAPI", .product(name: "JavaScriptKit", package: "JavaScriptKit"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "WebApp",
      dependencies: [
        "SessionLogic",
        "ProtocolModels",
        "RemoteProtocol",
        "RemoteClient",
        "BrowserAPI",
        .product(name: "ElementaryUI", package: "elementary-ui"),
        .product(name: "ElementaryRouter", package: "elementary-router"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ],
    )
  ]
)
