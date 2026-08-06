// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ComputerUseMacOS",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "computer-use-pilot",
      targets: ["ComputerUsePilot"]
    ),
    .library(
      name: "ComputerUsePilotCore",
      targets: ["ComputerUsePilotCore"]
    )
  ],
  targets: [
    .target(
      name: "ComputerUsePilotCore",
      resources: [.process("Resources")],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AppKit"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ScreenCaptureKit")
      ]
    ),
    .executableTarget(
      name: "ComputerUsePilot",
      dependencies: ["ComputerUsePilotCore"]
    ),
    .testTarget(
      name: "ComputerUsePilotCoreTests",
      dependencies: ["ComputerUsePilotCore"]
    )
  ]
)
