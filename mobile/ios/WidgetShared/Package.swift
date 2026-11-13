// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WidgetCore", platforms: [.macOS(.v13), .iOS(.v16)], products: [.library(name: "WidgetCore", targets: ["WidgetCore"])], targets: [.target(name: "WidgetCore"), .testTarget(name: "WidgetCoreTests", dependencies: ["WidgetCore"])])
