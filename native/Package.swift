// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "AgentDeck", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AgentDeck", targets: ["AgentDeck"]),
    .library(name: "AlfredIntegration", targets: ["AlfredIntegration"]),
    .executable(name: "deck-service", targets: ["DeckService"]),
    .executable(name: "deck-hook", targets: ["DeckHook"]),
    .executable(name: "install-hooks", targets: ["DeckInstaller"]),
  ],
  dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "MasterHUBUSB", cSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit"), .linkedFramework("Foundation")]),
    .target(name: "DeckCore", dependencies: ["CSQLite"]),
    .target(name: "DeckTransport", dependencies: ["DeckCore"]),
    .target(name: "AlfredIntegration", dependencies: ["DeckCore"]),
    .executableTarget(name: "DeckService", dependencies: ["DeckCore", "DeckTransport"]),
    .executableTarget(name: "DeckHook", dependencies: ["DeckTransport", "DeckCore"]),
    .executableTarget(name: "DeckInstaller", dependencies: ["DeckCore"]),
    .executableTarget(
      name: "AgentDeck", dependencies: ["DeckCore", "AlfredIntegration", "MasterHUBUSB", .product(name: "Sparkle", package: "Sparkle")],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .testTarget(name: "DeckCoreTests", dependencies: ["DeckCore"]),
  ])
