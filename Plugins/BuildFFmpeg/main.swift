import Foundation

do {
    try BuildFFmpeg.performCommand(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    print(error.localizedDescription)
    exit(0)
}

private enum Library: String, CaseIterable {
    case gnutls, gmp, nettle, readline, libdovi
    var version: String {
        return "libdovi-3.3.0"
    }

    var url: String {
        return "https://github.com/quietvoid/dovi_tool"
        
    }
}


enum BuildFFmpeg {
    static func performCommand(arguments: [String]) throws {
        if Utility.shell("which brew") == nil {
            print("""
            You need to run the script first
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            """)
            return
        }
        if Utility.shell("which pkg-config") == nil {
            Utility.shell("brew install pkg-config")
        }
        let path = URL.currentDirectory + "Script"
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: nil)
        }
        FileManager.default.changeCurrentDirectoryPath(path.path)
        BaseBuild.isDebug = arguments.firstIndex(of: "enable-debug") != nil
        BaseBuild.platforms = arguments.compactMap { argument in
            if argument.hasPrefix("platform=") {
                let value = String(argument.suffix(argument.count - "platform=".count))
                return PlatformType(rawValue: value)
            } else {
                return nil
            }
        }
        if BaseBuild.platforms.isEmpty {
            BaseBuild.platforms = PlatformType.allCases
        }

        try BuildDovi().buildALL()
    }
}


private class BuildDovi: BaseBuild {
    init() throws {
        super.init(library: .libdovi)

        if Utility.shell("which cargo") == nil {
            throw NSError(domain: "Please manually install cargo: https://doc.rust-lang.org/cargo/getting-started/installation.html", code: 1)
        }
    }

    override func buildALL() throws {
        try super.buildALL()

        // // 生成打包文件
        let releaseURL = URL.currentDirectory + "../Release"
        let workdirURL = releaseURL + "/libdovi"
        try? FileManager.default.removeItem(at: releaseURL)
        try? FileManager.default.createDirectory(at: workdirURL, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: URL.currentDirectory + "../Sources/Libdovi.xcframework", to: releaseURL + "/Libdovi.xcframework")
        try? FileManager.default.copyItem(at: URL.currentDirectory + "/libdovi", to: workdirURL + "/lib")
        try? FileManager.default.copyItem(at: URL.currentDirectory + "/libdovi/ios/thin/arm64/include", to: workdirURL + "/include")
        Utility.shell("find . -name *.framework | xargs rm -rf", currentDirectoryURL: workdirURL + "/lib")
        Utility.shell("find . -name *.dylib | xargs rm -rf", currentDirectoryURL: workdirURL + "/lib")
        Utility.shell("find . -name pkgconfig | xargs rm -rf", currentDirectoryURL: workdirURL + "/lib")
        Utility.shell("find . -name include | xargs rm -rf", currentDirectoryURL: workdirURL + "/lib")
        Utility.shell("find . -name *.log | xargs rm -rf", currentDirectoryURL: releaseURL)
        Utility.shell("find . -name *.DS_Store | xargs rm -rf", currentDirectoryURL: releaseURL)

        let version = Library.libdovi.version.replacingOccurrences(of: "libdovi-", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        Utility.shell("zip -qr Libdovi.xcframework.zip Libdovi.xcframework", currentDirectoryURL: releaseURL)
        Utility.shell("swift package compute-checksum Libdovi.xcframework.zip > checksum.txt", currentDirectoryURL: releaseURL)
        Utility.shell("tar -cf libdovi-\(version).tar libdovi", currentDirectoryURL: releaseURL)
        
    }

    override func build(platform: PlatformType, arch: ArchType) throws {
        var target = platform.rustTarget(arch: arch)
        if target == "x86_64-apple-ios-sim" {
            target = "x86_64-apple-ios"
        }
        if target == "x86_64-apple-tvos-sim" {
            target = "x86_64-apple-tvos"
        }

        let prefix = thinDir(platform: platform, arch: arch)
        let currentDirectoryURL = directoryURL + "dolby_vision"
        let environ = environment(platform: platform, arch: arch)

        let cargo = Utility.shell("which cargo", isOutput: true)!
        try Utility.launch(path: cargo, arguments: ["+stage1", "cinstall", "-Zbuild-std=std,panic_abort", "--release", "--prefix=\(prefix.path)", "--target=\(target)"] , currentDirectoryURL: currentDirectoryURL, environment: environ)
    }
}

    

private class BaseBuild {
    static var platforms = PlatformType.allCases
    static var isDebug: Bool = false
    private let library: Library
    let directoryURL: URL
    init(library: Library) {
        self.library = library
        directoryURL = URL.currentDirectory + "\(library.rawValue)-\(library.version)"
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try! Utility.launch(path: "/usr/bin/git", arguments: ["-c", "advice.detachedHead=false", "clone", "--depth", "1", "--branch", library.version, library.url, directoryURL.path])
        }
    }

    func buildALL() throws {
        try? FileManager.default.removeItem(at: URL.currentDirectory + library.rawValue)
        for platform in BaseBuild.platforms {
            for arch in architectures(platform) {
                try build(platform: platform, arch: arch)
            }
        }
        try createXCFramework()
    }

    func architectures(_ platform: PlatformType) -> [ArchType] {
        platform.architectures
    }

    func platforms() -> [PlatformType] {
        BaseBuild.platforms
    }

    func build(platform: PlatformType, arch: ArchType) throws {
        let buildURL = scratch(platform: platform, arch: arch)
        try? FileManager.default.createDirectory(at: buildURL, withIntermediateDirectories: true, attributes: nil)
        let environ = environment(platform: platform, arch: arch)
        if FileManager.default.fileExists(atPath: (directoryURL + "meson.build").path) {
            if Utility.shell("which meson") == nil {
                Utility.shell("brew install meson")
            }
            if Utility.shell("which ninja") == nil {
                Utility.shell("brew install ninja")
            }
            // Utility.shell("brew install python3-jinja2")
            // let python3 = Utility.shell("which python3", isOutput: true)!
            // Utility.shell("/usr/bin/python3 -m pip install setuptools")
            // Utility.shell("/usr/bin/python3 -m pip install wheel")
            

            let crossFile = createMesonCrossFile(platform: platform, arch: arch)
            let meson = Utility.shell("which meson", isOutput: true)!
            try Utility.launch(path: meson, arguments: ["setup", buildURL.path, "--cross-file=\(crossFile.path)"] + arguments(platform: platform, arch: arch), currentDirectoryURL: directoryURL, environment: environ)
            try Utility.launch(path: meson, arguments: ["compile", "--clean"], currentDirectoryURL: buildURL, environment: environ)
            try Utility.launch(path: meson, arguments: ["compile", "--verbose"], currentDirectoryURL: buildURL, environment: environ)
            try Utility.launch(path: meson, arguments: ["install"], currentDirectoryURL: buildURL, environment: environ)
        } else if FileManager.default.fileExists(atPath: (directoryURL + wafPath()).path) {
            try Utility.launch(path: "/usr/bin/python3", arguments: [wafPath(), "distclean"], currentDirectoryURL: directoryURL, environment: environ)
            try Utility.launch(path: "/usr/bin/python3", arguments: [wafPath(), "configure"] + arguments(platform: platform, arch: arch), currentDirectoryURL: directoryURL, environment: environ)
            try runWafTargets(platform: platform, arch: arch)
            try Utility.launch(path: "/usr/bin/python3", arguments: ["./buildtools/bin/waf", "--targets=client/smbclient"], currentDirectoryURL: directoryURL, environment: environ)

            try Utility.launch(path: "/usr/bin/python3", arguments: [wafPath(), "build"], currentDirectoryURL: directoryURL, environment: environ)
            try Utility.launch(path: "/usr/bin/python3", arguments: [wafPath(), "install"], currentDirectoryURL: directoryURL, environment: environ)
        } else {
            try configure(buildURL: buildURL, environ: environ, platform: platform, arch: arch)
            try Utility.launch(path: "/usr/bin/make", arguments: ["-j8"], currentDirectoryURL: buildURL, environment: environ)
            try Utility.launch(path: "/usr/bin/make", arguments: ["-j8", "install"], currentDirectoryURL: buildURL, environment: environ)
        }
    }

    func wafPath() -> String {
        "./waf"
    }

    func runWafTargets(platform _: PlatformType, arch _: ArchType) throws {}

    func configure(buildURL: URL, environ: [String: String], platform: PlatformType, arch: ArchType) throws {
        let autogen = directoryURL + "autogen.sh"
        if FileManager.default.fileExists(atPath: autogen.path) {
            var environ = environ
            environ["NOCONFIGURE"] = "1"
            try Utility.launch(executableURL: autogen, arguments: [], currentDirectoryURL: directoryURL, environment: environ)
        }
        let makeLists = directoryURL + "CMakeLists.txt"
        if FileManager.default.fileExists(atPath: makeLists.path) {
            if Utility.shell("which cmake") == nil {
                Utility.shell("brew install cmake")
            }
            let cmake = Utility.shell("which cmake", isOutput: true)!
            let thinDirPath = thinDir(platform: platform, arch: arch).path
            var arguments = [
                makeLists.path,
                "-DCMAKE_VERBOSE_MAKEFILE=0",
                "-DCMAKE_BUILD_TYPE=Release",
                "-DCMAKE_OSX_SYSROOT=\(platform.sdk.lowercased())",
                "-DCMAKE_OSX_ARCHITECTURES=\(arch.rawValue)",
                "-DCMAKE_INSTALL_PREFIX=\(thinDirPath)",
                "-DBUILD_SHARED_LIBS=0",
            ]
            arguments.append(contentsOf: self.arguments(platform: platform, arch: arch))
            try Utility.launch(path: cmake, arguments: arguments, currentDirectoryURL: buildURL, environment: environ)
        } else {
            let configure = directoryURL + "configure"
            if !FileManager.default.fileExists(atPath: configure.path) {
                var bootstrap = directoryURL + "bootstrap"
                if !FileManager.default.fileExists(atPath: bootstrap.path) {
                    bootstrap = directoryURL + ".bootstrap"
                }
                if FileManager.default.fileExists(atPath: bootstrap.path) {
                    try Utility.launch(executableURL: bootstrap, arguments: [], currentDirectoryURL: directoryURL, environment: environ)
                }
            }
            var arguments = [
                "--prefix=\(thinDir(platform: platform, arch: arch).path)",
            ]
            arguments.append(contentsOf: self.arguments(platform: platform, arch: arch))
            try Utility.launch(executableURL: configure, arguments: arguments, currentDirectoryURL: buildURL, environment: environ)
        }
    }

    private func pkgConfigPath(platform: PlatformType, arch: ArchType) -> String {
        var pkgConfigPath = ""
        for lib in Library.allCases {
            let path = URL.currentDirectory + [lib.rawValue, platform.rawValue, "thin", arch.rawValue]
            if FileManager.default.fileExists(atPath: path.path) {
                pkgConfigPath += "\(path.path)/lib/pkgconfig:"
            }
        }
        return pkgConfigPath
    }

    func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        let cFlags = platform.cFlags(arch: arch).joined(separator: " ")
        let pkgConfigPathDefault = Utility.shell("pkg-config --variable pc_path pkg-config", isOutput: true)!
        return [
            "LC_CTYPE": "C",
            "CC": "/usr/bin/clang",
            "CXX": "/usr/bin/clang++",
            // "SDKROOT": platform.sdk.lowercased(),
            "CURRENT_ARCH": arch.rawValue,
            "CFLAGS": cFlags,
            // makefile can't use CPPFLAGS
            "CPPFLAGS": cFlags,
            "CXXFLAGS": cFlags,
            "LDFLAGS": platform.ldFlags(arch: arch).joined(separator: " "),
            "PKG_CONFIG_LIBDIR": platform.pkgConfigPath(arch: arch) + pkgConfigPathDefault,
            // "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/local/opt/bison/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }


    func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        return []
    }

    func frameworks() throws -> [String] {
        [library.rawValue]
    }

    func createXCFramework() throws {
        var frameworks: [String] = []
        let libNames = try self.frameworks()
        for libName in libNames {
            if libName.hasPrefix("lib") {
                frameworks.append("Lib" + libName.dropFirst(3))
            } else {
                frameworks.append(libName)
            }
        }
        for framework in frameworks {
            var arguments = ["-create-xcframework"]
            for platform in BaseBuild.platforms {
                if let frameworkPath = try createFramework(framework: framework, platform: platform) {
                    arguments.append("-framework")
                    arguments.append(frameworkPath)
                }
            }
            arguments.append("-output")
            let XCFrameworkFile = URL.currentDirectory + ["../Sources", framework + ".xcframework"]
            arguments.append(XCFrameworkFile.path)
            if FileManager.default.fileExists(atPath: XCFrameworkFile.path) {
                try? FileManager.default.removeItem(at: XCFrameworkFile)
            }
            try Utility.launch(path: "/usr/bin/xcodebuild", arguments: arguments)
        }
    }

    private func createFramework(framework: String, platform: PlatformType) throws -> String? {
        let frameworkDir = URL.currentDirectory + [library.rawValue, platform.rawValue, "\(framework).framework"]
        if !platforms().contains(platform) {
            if FileManager.default.fileExists(atPath: frameworkDir.path) {
                return frameworkDir.path
            } else {
                return nil
            }
        }
        try? FileManager.default.removeItem(at: frameworkDir)
        try FileManager.default.createDirectory(at: frameworkDir, withIntermediateDirectories: true, attributes: nil)
        var arguments = ["-create"]
        for arch in platform.architectures {
            let prefix = thinDir(platform: platform, arch: arch)
            if !FileManager.default.fileExists(atPath: prefix.path) {
                return nil
            }
            let libname = framework.hasPrefix("lib") || framework.hasPrefix("Lib") ? framework : "lib" + framework
            var libPath = prefix + ["lib", "\(libname).a"]
            if !FileManager.default.fileExists(atPath: libPath.path) {
                libPath = prefix + ["lib", "\(libname).dylib"]
            }
            arguments.append(libPath.path)
            var headerURL: URL = prefix + "include" + framework
            if !FileManager.default.fileExists(atPath: headerURL.path) {
                headerURL = prefix + "include"
            }
            try? FileManager.default.copyItem(at: headerURL, to: frameworkDir + "Headers")
        }
        arguments.append("-output")
        arguments.append((frameworkDir + framework).path)
        try Utility.launch(path: "/usr/bin/lipo", arguments: arguments)
        try FileManager.default.createDirectory(at: frameworkDir + "Modules", withIntermediateDirectories: true, attributes: nil)
        var modulemap = """
        framework module \(framework) [system] {
            umbrella "."

        """
        frameworkExcludeHeaders(framework).forEach { header in
            modulemap += """
                exclude header "\(header).h"

            """
        }
        modulemap += """
            export *
        }
        """
        FileManager.default.createFile(atPath: frameworkDir.path + "/Modules/module.modulemap", contents: modulemap.data(using: .utf8), attributes: nil)
        createPlist(path: frameworkDir.path + "/Info.plist", name: framework, minVersion: platform.minVersion, platform: platform.sdk)
        return frameworkDir.path
    }

    func thinDir(platform: PlatformType, arch: ArchType) -> URL {
        URL.currentDirectory + [library.rawValue, platform.rawValue, "thin", arch.rawValue]
    }

    func scratch(platform: PlatformType, arch: ArchType) -> URL {
        URL.currentDirectory + [library.rawValue, platform.rawValue, "scratch", arch.rawValue]
    }

    func frameworkExcludeHeaders(_: String) -> [String] {
        []
    }

    private func createPlist(path: String, name: String, minVersion: String, platform: String) {
        let identifier = "com.kintan.ksplayer." + name
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleExecutable</key>
        <string>\(name)</string>
        <key>CFBundleIdentifier</key>
        <string>\(identifier)</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>\(name)</string>
        <key>CFBundlePackageType</key>
        <string>FMWK</string>
        <key>CFBundleShortVersionString</key>
        <string>87.88.520</string>
        <key>CFBundleVersion</key>
        <string>87.88.520</string>
        <key>CFBundleSignature</key>
        <string>????</string>
        <key>MinimumOSVersion</key>
        <string>\(minVersion)</string>
        <key>CFBundleSupportedPlatforms</key>
        <array>
        <string>\(platform)</string>
        </array>
        <key>NSPrincipalClass</key>
        <string></string>
        </dict>
        </plist>
        """
        FileManager.default.createFile(atPath: path, contents: content.data(using: .utf8), attributes: nil)
    }


    private func createMesonCrossFile(platform: PlatformType, arch: ArchType) -> URL {
        let url = scratch(platform: platform, arch: arch)
        let crossFile = url + "crossFile.meson"
        let prefix = thinDir(platform: platform, arch: arch)
        let cFlags = platform.cFlags(arch: arch).map {
            "'" + $0 + "'"
        }.joined(separator: ", ")
        let ldFlags = platform.ldFlags(arch: arch).map {
            "'" + $0 + "'"
        }.joined(separator: ", ")
        let content = """
        [binaries]
        c = '/usr/bin/clang'
        cpp = '/usr/bin/clang++'
        objc = '/usr/bin/clang'
        objcpp = '/usr/bin/clang++'
        ar = '\(platform.xcrunFind(tool: "ar"))'
        strip = '\(platform.xcrunFind(tool: "strip"))'
        pkg-config = 'pkg-config'

        [properties]
        has_function_printf = true
        has_function_hfkerhisadf = false

        [host_machine]
        system = 'darwin'
        subsystem = '\(platform.mesonSubSystem)'
        kernel = 'xnu'
        cpu_family = '\(arch.cpuFamily)'
        cpu = '\(arch.targetCpu)'
        endian = 'little'

        [built-in options]
        default_library = 'static'
        buildtype = 'release'
        prefix = '\(prefix.path)'
        c_args = [\(cFlags)]
        cpp_args = [\(cFlags)]
        objc_args = [\(cFlags)]
        objcpp_args = [\(cFlags)]
        c_link_args = [\(ldFlags)]
        cpp_link_args = [\(ldFlags)]
        objc_link_args = [\(ldFlags)]
        objcpp_link_args = [\(ldFlags)]
        """
        FileManager.default.createFile(atPath: crossFile.path, contents: content.data(using: .utf8), attributes: nil)
        return crossFile
    }
}


private enum PlatformType: String, CaseIterable {
    case ios, isimulator, tvos, tvsimulator, macos, maccatalyst
    var minVersion: String {
        switch self {
        case .ios, .isimulator:
            return "13.0"
        case .tvos, .tvsimulator:
            return "13.0"
        case .macos:
            return "10.15"
        case .maccatalyst:
            // return "14.0"
            return ""
        }
    }

    var name: String {
        switch self {
        case .ios, .tvos, .macos:
            return rawValue
        case .tvsimulator:
            return "tvossim"
        case .isimulator:
            return "iossim"
        case .maccatalyst:
            return "maccat"
        }
    }

    var frameworkName: String {
        switch self {
        case .ios:
            return "ios-arm64"
        case .maccatalyst:
            return "ios-arm64_x86_64-maccatalyst"
        case .isimulator:
            return "ios-arm64_x86_64-simulator"
        case .macos:
            return "macos-arm64_x86_64"
        case .tvos:
            // 保持和xcode一致：https://github.com/KhronosGroup/MoltenVK/issues/431#issuecomment-771137085
            return "tvos-arm64_arm64e"
        case .tvsimulator:
            return "tvos-arm64_x86_64-simulator"
        }
    }


    var architectures: [ArchType] {
        switch self {
        case .ios:
            return [.arm64]
        case .tvos:
            // 保持和xcode一致：https://github.com/KhronosGroup/MoltenVK/issues/431#issuecomment-771137085
            return [.arm64, .arm64e]
        case .isimulator, .tvsimulator:
            return [.arm64, .x86_64]
        case .macos:
            // macos 不能用arm64，不然打包release包会报错，不能通过
            #if arch(x86_64)
            return [.x86_64, .arm64]
            #else
            return [.arm64, .x86_64]
            #endif
        case .maccatalyst:
            return [.arm64, .x86_64]
        }
    }

    fileprivate func deploymentTarget(_ arch: ArchType) -> String {
        switch self {
        case .ios, .tvos, .macos:
            return "\(arch.targetCpu)-apple-\(rawValue)\(minVersion)"
        case .maccatalyst:
            return "\(arch.targetCpu)-apple-ios\(minVersion)-macabi"
        case .isimulator:
            return PlatformType.ios.deploymentTarget(arch) + "-simulator"
        case .tvsimulator:
            return PlatformType.tvos.deploymentTarget(arch) + "-simulator"
        // case .watchsimulator:
        //     return PlatformType.watchos.deploymentTarget(arch) + "-simulator"
        // case .xrsimulator:
        //     return PlatformType.xros.deploymentTarget(arch) + "-simulator"
        }
    }

    func rustTarget(arch: ArchType) -> String {
        switch self {
        case .ios:
            return "\(arch.cpuFamily)-apple-ios"
        case .isimulator:
            return "\(arch.cpuFamily)-apple-ios-sim"
        case .tvos:
            return "\(arch == .arm64e ? "arm64e" : "\(arch.cpuFamily)")-apple-tvos"
        case .tvsimulator:
            return "\(arch.cpuFamily)-apple-tvos-sim"
        case .macos:
            return "\(arch.cpuFamily)-apple-darwin"
        case .maccatalyst:
            return "\(arch.cpuFamily)-apple-ios-macabi"
        }
    }

    private var osVersionMin: String {
        switch self {
        case .ios, .tvos:
            return "-m\(rawValue)-version-min=\(minVersion)"
        case .macos:
            return "-mmacosx-version-min=\(minVersion)"
        case .isimulator:
            return "-mios-simulator-version-min=\(minVersion)"
        case .tvsimulator:
            return "-mtvos-simulator-version-min=\(minVersion)"
        case .maccatalyst:
            // return "-miphoneos-version-min=\(minVersion)"
            return ""
        }
    }

    var sdk : String {
        switch self {
        case .ios:
            return "iPhoneOS"
        case .isimulator:
            return "iPhoneSimulator"
        case .tvos:
            return "AppleTVOS"
        case .tvsimulator:
            return "AppleTVSimulator"
        case .macos:
            return "MacOSX"
        case .maccatalyst:
            return "MacOSX"
        }
    }

    var isysroot: String {
        xcrunFind(tool: "--show-sdk-path")
    }

    var mesonSubSystem: String {
        switch self {
        case .isimulator:
            return "ios-simulator"
        case .tvsimulator:
            return "tvos-simulator"
        // case .xrsimulator:
        //     return "xros-simulator"
        // case .watchsimulator:
        //     return "watchos-simulator"
        default:
            return rawValue
        }
    }

    func host(arch: ArchType) -> String {
        switch self {
        case .ios, .isimulator, .maccatalyst:
            return "\(arch == .x86_64 ? "x86_64" : "arm64")-ios-darwin"
        case .tvos, .tvsimulator:
            return "\(arch == .x86_64 ? "x86_64" : "arm64")-tvos-darwin"
        case .macos:
            return "\(arch == .x86_64 ? "x86_64" : "arm64")-apple-darwin"
        }
    }

    func ldFlags(arch: ArchType) -> [String] {
        // ldFlags的关键参数要跟cFlags保持一致，不然会在ld的时候不通过。
        var flags = ["-lc++", "-arch", arch.rawValue, "-isysroot", isysroot, "-target", deploymentTarget(arch), osVersionMin]
        // 为了maccatalyst能正常加载UIKit框架
        if self == .maccatalyst {
            flags.append("-iframework \(isysroot)/System/iOSSupport/System/Library/Frameworks")
        }
        let librarys: [Library] = [.gmp, .nettle, .readline, .gnutls]
        for library in librarys {
            let path = URL.currentDirectory + [library.rawValue, rawValue, "thin", arch.rawValue]
            if FileManager.default.fileExists(atPath: path.path) {
                var libname = library.rawValue
                if library == .nettle {
                    libname += " -lhogweed"
                } else if library == .gnutls {
                    libname += " -framework Security -framework CoreFoundation"
                }
                flags.append("-L\(path.path)/lib -l\(libname)")
            }
        }
        return flags
    }


    func cFlags(arch: ArchType) -> [String] {
        var cflags = ["-arch", arch.rawValue, "-isysroot", isysroot, "-target", deploymentTarget(arch), osVersionMin]
//        if self == .macos || self == .maccatalyst {
        // 不能同时有强符合和弱符号出现
        // cflags.append("-fno-common")
//        }
        if self == .tvos || self == .tvsimulator {
            cflags.append("-DHAVE_FORK=0")
        }
        let librarys: [Library] = [.gmp, .nettle, .readline, .gnutls]
        for library in librarys {
            let path = URL.currentDirectory + [library.rawValue, rawValue, "thin", arch.rawValue]
            if FileManager.default.fileExists(atPath: path.path) {
                cflags.append("-I\(path.path)/include")
            }
        }
        return cflags
    }

    func xcrunFind(tool: String) -> String {
        try! Utility.launch(path: "/usr/bin/xcrun", arguments: ["--sdk", sdk.lowercased(), "--find", tool], isOutput: true)
    }

    func pkgConfigPath(arch: ArchType) -> String {
        var pkgConfigPath = ""
        for lib in Library.allCases {
            let path = URL.currentDirectory + [lib.rawValue, rawValue, "thin", arch.rawValue]
            if FileManager.default.fileExists(atPath: path.path) {
                pkgConfigPath += "\(path.path)/lib/pkgconfig:"
            }
        }
        return pkgConfigPath
    }
}

enum ArchType: String, CaseIterable {
    // swiftlint:disable identifier_name
    case arm64, x86_64, arm64e
    // swiftlint:enable identifier_name
    var executable: Bool {
        guard let architecture = Bundle.main.executableArchitectures?.first?.intValue else {
            return false
        }
        // NSBundleExecutableArchitectureARM64
        if architecture == 0x0100_000C, self == .arm64 {
            return true
        } else if architecture == NSBundleExecutableArchitectureX86_64, self == .x86_64 {
            return true
        }
        return false
    }

    var cpuFamily: String {
        switch self {
        case .arm64, .arm64e:
            return "aarch64"
        case .x86_64:
            return "x86_64"
        }
    }

    var targetCpu: String {
        switch self {
        case .arm64, .arm64e:
            return "arm64"
        case .x86_64:
            return "x86_64"
        }
    }
}

enum Utility {
    @discardableResult
    static func shell(_ command: String, isOutput : Bool = false, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) -> String? {
        do {
            return try launch(executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", command], isOutput: isOutput, currentDirectoryURL: currentDirectoryURL, environment: environment)
        } catch {
            print(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    static func launch(path: String, arguments: [String], isOutput: Bool = false, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) throws -> String {
        try launch(executableURL: URL(fileURLWithPath: path), arguments: arguments, isOutput: isOutput, currentDirectoryURL: currentDirectoryURL, environment: environment)
    }

    @discardableResult
    static func launch(executableURL: URL, arguments: [String], isOutput: Bool = false, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) throws -> String {
        #if os(macOS)
        let task = Process()
        var environment = environment
        // for homebrew 1.12
        if ProcessInfo.processInfo.environment.keys.contains("HOME") {
            environment["HOME"] = ProcessInfo.processInfo.environment["HOME"]
        }
        if !environment.keys.contains("PATH") {
            let cargo = environment["HOME"] ?? ""
            environment["PATH"] = "\(cargo)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        task.environment = environment

        var outputFileHandle: FileHandle?
        var logURL: URL?
        var outputBuffer = Data()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        if let curURL = currentDirectoryURL {
            // output to file
            logURL = curURL.appendingPathExtension("log")
            if !FileManager.default.fileExists(atPath: logURL!.path) {
                FileManager.default.createFile(atPath: logURL!.path, contents: nil)
            }

            outputFileHandle = try FileHandle(forWritingTo: logURL!)
            // outputFileHandle?.seekToEndOfFile()
        }
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData

            if !data.isEmpty {
                outputBuffer.append(data)
                if let outputString = String(data: data, encoding: .utf8) {
                    if isOutput {
                        print(outputString.trimmingCharacters(in: .newlines))
                    }

                    // Write to file simultaneously.
                    outputFileHandle?.write(data)
                }
            } else {
                // Close the read capability processing program and clean up resources.
                fileHandle.readabilityHandler = nil
                fileHandle.closeFile()
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData

            if !data.isEmpty {
                if let outputString = String(data: data, encoding: .utf8) {
                    print(outputString.trimmingCharacters(in: .newlines))

                    // Write to file simultaneously.
                    outputFileHandle?.write(data)
                }
            } else {
                // Close the read capability processing program and clean up resources.
                fileHandle.readabilityHandler = nil
                fileHandle.closeFile()
            }
        }
    
        task.arguments = arguments
        var log = executableURL.path + " " + arguments.joined(separator: " ") + " environment: " + environment.description
        if let currentDirectoryURL {
            log += " url: \(currentDirectoryURL)"
        }
        print(log)
        outputFileHandle?.write("\(log)\n".data(using: .utf8)!)
        task.currentDirectoryURL = currentDirectoryURL
        task.executableURL = executableURL
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            if isOutput {
                let result = String(data: outputBuffer, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
                return result
            } else {
                return ""
            }
        } else {
            if let logURL = logURL {
                print("please view log file for detail: \(logURL)\n")
            }
            throw NSError(domain: "fail", code: Int(task.terminationStatus))
        }
        #else
        return ""
        #endif
    }
}

extension URL {
    static var currentDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static func + (left: URL, right: String) -> URL {
        var url = left
        url.appendPathComponent(right)
        return url
    }

    static func + (left: URL, right: [String]) -> URL {
        var url = left
        right.forEach {
            url.appendPathComponent($0)
        }
        return url
    }
}
