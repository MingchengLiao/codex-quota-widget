// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CodexQuotaWidget",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "CodexQuotaWidget", targets: ["CodexQuotaWidget"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaWidget",
            path: "Sources/CodexQuotaWidget"
        ),
    ]
)
