// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FitbitMetrics",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FitbitMetrics", targets: ["FitbitMetrics"]),
        .executable(name: "metrics-cli", targets: ["MetricsCLI"]),
        .library(name: "AirSync", targets: ["AirSync"]),
        .library(name: "AirAuth", targets: ["AirAuth"]),
        .library(name: "AirUI", targets: ["AirUI"]),
        .executable(name: "form-preview", targets: ["AirPreview"])
    ],
    targets: [
        .target(name: "FitbitMetrics"),
        .executableTarget(name: "MetricsCLI", dependencies: ["FitbitMetrics"]),
        .target(name: "AirSync", dependencies: ["FitbitMetrics"]),
        .target(name: "AirAuth"),
        .target(name: "AirUI", dependencies: ["FitbitMetrics", "AirSync", "AirAuth"]),
        .executableTarget(name: "AirPreview", dependencies: ["AirUI", "FitbitMetrics"]),
        .testTarget(name: "FitbitMetricsTests", dependencies: ["FitbitMetrics"], path: "tests/FitbitMetricsTests"),
        .testTarget(name: "AirSyncTests", dependencies: ["AirSync", "FitbitMetrics"], path: "tests/AirSyncTests", exclude: ["make_parity_fixture.py"]),
        .testTarget(name: "AirAuthTests", dependencies: ["AirAuth"], path: "tests/AirAuthTests"),
        .testTarget(name: "AirUITests", dependencies: ["AirUI", "FitbitMetrics"], path: "tests/AirUITests")
    ]
)
