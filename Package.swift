// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS("27.0")],   // Liquid Glass (NSGlassEffectView, .glass bezels)
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", from: "0.25.0"),
        .package(url: "https://github.com/elixir-lang/tree-sitter-elixir.git", from: "0.3.5"),
        .package(url: "https://github.com/phoenixframework/tree-sitter-heex.git", from: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python.git", exact: "0.23.6"),   // ponytail: newer manifests add scanner.c via a cwd-relative fileExists, which SwiftBuild misses
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript.git", exact: "0.23.1"),   // ponytail: newer manifests add scanner.c via a cwd-relative fileExists, which SwiftBuild misses
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript.git", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go.git", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust.git", from: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby.git", from: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java.git", from: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c.git", from: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp.git", from: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp.git", from: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json.git", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash.git", from: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html.git", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css.git", exact: "0.23.2"),   // ponytail: newer manifests add scanner.c via a cwd-relative fileExists, which SwiftBuild misses
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift.git", branch: "with-generated-files"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml.git", exact: "0.7.0"),   // ponytail: newer manifests add scanner.c via a cwd-relative fileExists, which SwiftBuild misses
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml.git", from: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-lua.git", exact: "0.3.0"),   // ponytail: newer manifests add scanner.c via a cwd-relative fileExists, which SwiftBuild misses
        .package(url: "https://github.com/fwcd/tree-sitter-kotlin.git", from: "0.3.8"),
        .package(url: "https://github.com/camdencheek/tree-sitter-dockerfile.git", from: "0.2.0"),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        .executableTarget(name: "wbhost", path: "Sources/wbhost"),
        .executableTarget(
            name: "Workbench",
            dependencies: [
                "GhosttyKit",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterElixir", package: "tree-sitter-elixir"),
                .product(name: "TreeSitterHeex", package: "tree-sitter-heex"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
                .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin"),
                .product(name: "TreeSitterDockerfile", package: "tree-sitter-dockerfile"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("sqlite3"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit"),
            ]
        ),
    ]
)
