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
    // not anchor the separate jimage/verifier objects or the current java.net
    // entrypoints. Exact roots retain their archive members and dynamic exports.
    // Keep the builtin library hooks too: JNI_OnLoad_net initializes the IP
    // availability flags read by InetAddress. Merely retaining the JNI methods
    // leaves those flags zero. All names exist in both pinned native slices.
    let dynamicEntries = ["JIMAGE_Open", "JIMAGE_Close", "JIMAGE_FindResource", "JIMAGE_GetResource",
                          // jrt's NativeImageBuffer loads the builtin jimage
                          // library through this hook. Release dead-stripping
                          // otherwise removes it despite retaining JIMAGE_Open.
                          "JNI_OnLoad_jimage", "Java_jdk_internal_jimage_NativeImageBuffer_getNativeMap",
                          "VerifyClassForMajorVersion", "JNI_OnLoad_net", "JNI_OnLoad_nio",
                          "Java_java_net_InetAddress_isIPv4Available",
                          "Java_java_net_InetAddress_isIPv6Supported",
                          "Java_java_net_Inet4AddressImpl_getLocalHostName",
                          "Java_java_net_Inet4AddressImpl_lookupAllHostAddr",
                          "Java_java_net_Inet4AddressImpl_getHostByAddr",
                          "Java_java_net_Inet4AddressImpl_isReachable0",
                          "Java_java_net_Inet6AddressImpl_getLocalHostName",
                          "Java_java_net_Inet6AddressImpl_lookupAllHostAddr",
                          "Java_java_net_Inet6AddressImpl_getHostByAddr",
                          "Java_java_net_Inet6AddressImpl_isReachable0",
                          "Java_java_net_NetworkInterface_getAll",
                          "Java_java_net_NetworkInterface_getByName0",
                          "Java_java_net_NetworkInterface_getByIndex0",
                          "Java_java_net_NetworkInterface_boundInetAddress0",
                          "Java_java_net_NetworkInterface_getByInetAddress0",
                          "Java_java_net_NetworkInterface_isUp0",
                          "Java_java_net_NetworkInterface_isLoopback0",
                          "Java_java_net_NetworkInterface_supportsMulticast0",
                          "Java_java_net_NetworkInterface_isP2P0",
                          "Java_java_net_NetworkInterface_getMacAddr0",
                          "Java_java_net_NetworkInterface_getMTU0",
                          "Java_java_net_NetworkInterface_init",
                          "Java_sun_net_PortConfig_getLower0", "Java_sun_net_PortConfig_getUpper0",
                          "Java_sun_net_spi_DefaultProxySelector_init",
                          "Java_sun_net_spi_DefaultProxySelector_getSystemProxies",
                          "Java_sun_net_dns_ResolverConfigurationImpl_fallbackDomain0"]
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
