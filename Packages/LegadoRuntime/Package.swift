// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Source-only checkouts build diagnostic support without pretending to contain a JVM.
// build-zero.sh supplies this locally built, pinned artifact; no remote binary is fetched.
let artifact = "Artifacts/OpenJDK.xcframework"
let sourceOnly = ProcessInfo.processInfo.environment["LEGADO_RUNTIME_SOURCE_ONLY"] == "1"
let hasRuntime = !sourceOnly && FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + artifact)
var targets: [Target] = []
if hasRuntime { targets.append(.binaryTarget(name: "OpenJDK", path: artifact)) }
var nativeLinkerSettings: [LinkerSetting] = [.linkedFramework("Foundation"), .linkedLibrary("z"), .linkedLibrary("c++")]
if hasRuntime {
    // HotSpot's static iOS loader resolves these through dlsym. The keeper does
    // not anchor the separate jimage or legacy verifier objects. Exact roots
    // retain their archive members and dynamic exports without loading all code.
    let dynamicEntries = ["JIMAGE_Open", "JIMAGE_Close", "JIMAGE_FindResource", "JIMAGE_GetResource",
                          "VerifyClassForMajorVersion"]
    nativeLinkerSettings.append(.unsafeFlags(
        dynamicEntries.flatMap { ["-Xlinker", "-u", "-Xlinker", "_" + $0] },
        .when(platforms: [.iOS])
    ))
}
targets.append(.target(
    name: "CLegadoJNI", dependencies: hasRuntime ? [.target(name: "OpenJDK")] : [],
    publicHeadersPath: "include",
    cSettings: hasRuntime ? [.define("LGR_WITH_OPENJDK", to: "1")] : [],
    linkerSettings: nativeLinkerSettings
))
targets.append(.target(name: "LegadoRuntime", dependencies: ["CLegadoJNI"]))
targets.append(.testTarget(name: "LegadoRuntimeTests", dependencies: ["LegadoRuntime"]))

let package = Package(
    name: "LegadoRuntime", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LegadoRuntime", targets: ["LegadoRuntime"])],
    targets: targets, swiftLanguageModes: [.v6]
)
