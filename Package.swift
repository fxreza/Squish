// swift-tools-version:6.0
import PackageDescription
import Foundation

// The SquishApp target is owned by another agent and its source directory may still be
// empty. SwiftPM refuses to build a target with no sources, so the target is only declared
// once at least one .swift file exists in Sources/SquishApp. Nothing else needs to change
// when that agent adds its first file.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let appSourceDir = packageRoot.appendingPathComponent("Sources/SquishApp")
let appHasSources = ((try? FileManager.default.contentsOfDirectory(atPath: appSourceDir.path)) ?? [])
    .contains { $0.hasSuffix(".swift") }

var targets: [Target] = [
    .target(name: "SquishCore"),
    .executableTarget(name: "squish", dependencies: ["SquishCore"]),
]
var products: [Product] = [
    .library(name: "SquishCore", targets: ["SquishCore"]),
    .executable(name: "squish", targets: ["squish"]),
]

if appHasSources {
    targets.append(.executableTarget(name: "SquishApp", dependencies: ["SquishCore"]))
    products.append(.executable(name: "SquishApp", targets: ["SquishApp"]))
}

let package = Package(
    name: "Squish",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets
)
