// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WiiBalanceScale",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WiiBalanceScale", targets: ["WiiBalanceScale"]),
        .library(name: "WiiBalanceCore", targets: ["WiiBalanceCore"]),
    ],
    targets: [
        // Platform independent logic: Wii protocol, weight filtering, units and the weight journal.
        .target(name: "WiiBalanceCore"),

        // The macOS app: IOBluetooth transport and SwiftUI interface.
        .executableTarget(
            name: "WiiBalanceScale",
            dependencies: ["WiiBalanceCore"],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                // Embed Info.plist so the Bluetooth usage description is present even when run via `swift run`.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Resources/Info.plist",
                ]),
            ]
        ),

        .testTarget(name: "WiiBalanceCoreTests", dependencies: ["WiiBalanceCore"]),
    ]
)
