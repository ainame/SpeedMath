// swift-tools-version:6.4
import PackageDescription

let package = Package(
  name: "SpeedMath",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(url: "https://github.com/elementary-swift/elementary-ui.git", from: "0.9.1"),
    .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.62.0"),
  ],
  targets: [
    .executableTarget(
      name: "WebApp",
      dependencies: [
        .product(name: "ElementaryUI", package: "elementary-ui")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ],
    )
  ]
)
