// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIChalkboard",
    // NOTE: `.macOS(.v14)` only sets the *Apple* deployment floor -- it does
    // not exclude other platforms from this package. Windows has no
    // corresponding `platforms:` entry (SwiftPM has no such concept for
    // Windows), so this package resolves and builds there unaffected by
    // this line.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIChalkboard", targets: ["AIChalkboard"])
    ],
    targets: [
        // C++ shim for the Win32/COM APIs (GDI+, WIC, UI Automation) that
        // Swift cannot import directly. See Sources/CChalkboardWin for
        // details. On macOS this target's translation unit compiles to
        // empty (guarded by `#ifdef _WIN32`), and AIChalkboardCore does not
        // even depend on it there, so it has zero effect on the mac build.
        .target(
            name: "CChalkboardWin",
            path: "Sources/CChalkboardWin",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("UNICODE", .when(platforms: [.windows])),
                .define("_UNICODE", .when(platforms: [.windows]))
            ],
            linkerSettings: [
                .linkedLibrary("gdiplus", .when(platforms: [.windows])),
                .linkedLibrary("gdi32", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                .linkedLibrary("oleaut32", .when(platforms: [.windows])),
                .linkedLibrary("uuid", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("shcore", .when(platforms: [.windows])),
                .linkedLibrary("dwmapi", .when(platforms: [.windows])),
                .linkedLibrary("windowscodecs", .when(platforms: [.windows]))
            ]
        ),
        .target(
            name: "AIChalkboardCore",
            dependencies: [
                // Only pulled in on Windows -- on macOS this target does not
                // exist in the dependency graph at all, so nothing there
                // changes.
                .target(name: "CChalkboardWin", condition: .when(platforms: [.windows]))
            ],
            path: "Sources",
            // CChalkboardWin lives at Sources/CChalkboardWin, a subdirectory
            // of this target's own path. Without this exclude, SwiftPM's
            // recursive source discovery for AIChalkboardCore would also
            // pick up CChalkboardWin's .cpp/.h files and reject the target
            // as "mixed language" (verified: this is a hard build error,
            // not a lint warning). CChalkboardWin is built and linked
            // entirely through the separate target declaration above.
            exclude: ["CChalkboardWin"],
            linkerSettings: [
                // user32: InstanceBroadcast's message-only-window IPC
                // (RegisterClassExW/CreateWindowExW/GetMessageW/
                // PostMessageW/SendMessageTimeoutW/FindWindowExW/
                // EnumWindows/IsWindowVisible and friends) and
                // SuspensionQuiescence's window-state discovery both call
                // straight into user32 from Swift via `import WinSDK` --
                // unlike GDI+/WIC/UIA, these are plain C APIs, so they need
                // no C++ shim, only the link library itself.
                .linkedLibrary("user32", .when(platforms: [.windows])),
                // dwmapi: SuspensionQuiescence's Windows twin (DwmFlush,
                // DwmGetWindowAttribute/DWMWA_CLOAKED) reads DWM state
                // directly for the same reason CChalkboardWin above already
                // links it for the render/capture shim -- this is a second,
                // independent Swift-side caller of the same system library.
                .linkedLibrary("dwmapi", .when(platforms: [.windows]))
            ]
        ),
        .executableTarget(
            name: "AIChalkboard",
            dependencies: ["AIChalkboardCore"],
            path: "Launcher"
        ),
        .testTarget(
            name: "AIChalkboardCoreTests",
            dependencies: ["AIChalkboardCore"],
            path: "tests/AIChalkboardCoreTests"
        )
    ]
)
