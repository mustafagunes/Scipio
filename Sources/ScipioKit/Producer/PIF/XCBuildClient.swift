import Foundation
import TSCBasic
import PackageGraph
import PackageModel

struct XCBuildClient {
    private let descriptionPackage: DescriptionPackage
    private let buildOptions: BuildOptions
    private let buildProduct: BuildProduct
    private let configuration: BuildConfiguration
    private let fileSystem: any FileSystem
    private let executor: any Executor

    init(
        package: DescriptionPackage,
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        configuration: BuildConfiguration,
        fileSystem: any FileSystem = localFileSystem,
        executor: any Executor = ProcessExecutor(decoder: StandardOutputDecoder())
    ) {
        self.descriptionPackage = package
        self.buildProduct = buildProduct
        self.buildOptions = buildOptions
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.executor = executor
    }

    private func fetchXCBuildPath() async throws -> AbsolutePath {
        let developerDirPath = try await fetchDeveloperDirPath()
        let relativePath = try RelativePath(validating: "../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild")
        return developerDirPath.appending(relativePath)
    }

    private func fetchDeveloperDirPath() async throws -> AbsolutePath {
        let result = try await executor.execute(
            "/usr/bin/xcrun",
            "xcode-select",
            "-p"
        )
        return try AbsolutePath(validating: try result.unwrapOutput())
    }

    private var productTargetName: String {
        let productName = buildProduct.target.name
        return "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
    }

    func buildFramework(
        sdk: SDK,
        pifPath: AbsolutePath,
        buildParametersPath: AbsolutePath
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()

        let executor = XCBuildExecutor(xcbuildPath: xcbuildPath)
        try await executor.build(
            pifPath: pifPath,
            configuration: configuration,
            derivedDataPath: descriptionPackage.derivedDataPath,
            buildParametersPath: buildParametersPath,
            target: buildProduct.target
        )

        try assembleFramework(sdk: sdk)

        // Copy modulemap to built frameworks
        // xcbuild generates modulemap for each frameworks
        // However, these are not includes in Frameworks
        // So they should be copied into frameworks manually.
//        try copyModulemap(for: sdk)
    }

    private func assembleFramework(sdk: SDK) throws {
        let modulemapGenerator = ModuleMapGenerator(
            descriptionPackage: descriptionPackage,
            fileSystem: fileSystem
        )
        // xcbuild automatically generates modulemaps. However, these are not for frameworks.
        // Therefore, it's difficult to contain to final XCFrameworks.
        // So generate modulemap for frameworks manually
        let frameworkModuleMapPath = try modulemapGenerator.generate(
            resolvedTarget: buildProduct.target,
            sdk: sdk,
            buildConfiguration: buildOptions.buildConfiguration
        )

        let frameworkOutputDir = descriptionPackage.generatedFrameworkDirectory.appending(
            component: productDirectoryName(sdk: sdk)
        )
        let productDir = descriptionPackage.derivedDataPath.appending(
            components: "Products", productDirectoryName(sdk: sdk)
        )

        let targetName = buildProduct.target.c99name

        let binaryPath = productDir.appending(component: targetName)

        let swiftModulesPath = try findSwiftModules(of: targetName, in: productDir)

        let bridgingHeaderPath = try findBridgingHeader(sdk: sdk)

        let publicHeaders = collectPublicHeader()

        let components = FrameworkComponents(
            name: buildProduct.target.name.packageNamed(),
            binaryPath: binaryPath,
            swiftModulesPath: swiftModulesPath,
            publicHeaderPaths: publicHeaders,
            bridgingHeaderPath: bridgingHeaderPath,
            modulemapPath: frameworkModuleMapPath
        )

        let assembler = FrameworkBundleAssembler(
            frameworkComponents: components,
            outputDirectory: frameworkOutputDir,
            fileSystem: fileSystem
        )

        try assembler.assemble()
    }

    /// Find *.swiftmodules*
    private func findSwiftModules(of targetName: String, in productDir: AbsolutePath) throws -> AbsolutePath? {
        let swiftModulesPath = productDir.appending(component: "\(targetName).swiftmodule")

        if fileSystem.exists(swiftModulesPath) {
            return swiftModulesPath
        }
        return nil
    }

    /// Find bridging header under $(SWIFT_OBJC_INTERFACE_HEADER_DIR)
    /// It will be $(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)/*-Swift.h
    private func findBridgingHeader(sdk: SDK) throws -> AbsolutePath? {
        let target = buildProduct.target
        let generatedModuleMapDirectoryPath = descriptionPackage.derivedDataPath.appending(
            components: "Intermediates.noindex", "GeneratedModuleMaps", sdk.settingValue
        )
        let generatedBridgingHeader = generatedModuleMapDirectoryPath.appending(component: "\(target.c99name)-Swift.h")

        if fileSystem.exists(generatedBridgingHeader) {
            return generatedBridgingHeader
        }

        return nil
    }

    /// Collect public headers of clangTarget
    private func collectPublicHeader() -> Set<AbsolutePath>? {
        guard let clangTarget = buildProduct.target.underlyingTarget as? ClangTarget else {
            return nil
        }

        let publicHeaders = clangTarget
            .headers
            .filter { $0.isDescendant(of: clangTarget.includeDir) }
        return Set(publicHeaders)
    }

    private func copyModulemap(for sdk: SDK) throws {
        let destinationFrameworkPath = try frameworkPath(target: buildProduct.target, of: sdk)
        let modulesDir = destinationFrameworkPath.appending(component: "Modules")
        if !fileSystem.exists(modulesDir) {
            try fileSystem.createDirectory(modulesDir)
        }

        let generatedModuleMapPath = try descriptionPackage.generatedModuleMapPath(of: buildProduct.target, sdk: sdk)
        if fileSystem.exists(generatedModuleMapPath) {
            let destination = modulesDir.appending(component: "module.modulemap")
            if fileSystem.exists(destination) {
                try fileSystem.removeFileTree(destination)
            }
            try fileSystem.copy(
                from: generatedModuleMapPath,
                to: destination
            )
        }
    }

    private func frameworkPath(target: ResolvedTarget, of sdk: SDK) throws -> AbsolutePath {
        let frameworkPath = try RelativePath(validating: productDirectoryName(sdk: sdk))
            .appending(component: "\(buildProduct.target.c99name).framework")
        return descriptionPackage.generatedFrameworkDirectory.appending(frameworkPath)
    }

    private func productDirectoryName(sdk: SDK) -> String {
        if sdk == .macOS {
            return configuration.settingsValue
        } else {
            return "\(configuration.settingsValue)-\(sdk.settingValue)"
        }
    }

    func createXCFramework(sdks: Set<SDK>, debugSymbols: [AbsolutePath]?, outputPath: AbsolutePath) async throws {
        let xcbuildPath = try await fetchXCBuildPath()

        let additionalArguments = try buildCreateXCFrameworkArguments(
            sdks: sdks,
            debugSymbols: debugSymbols,
            outputPath: outputPath
        )

        let arguments: [String] = [
            xcbuildPath.pathString,
            "createXCFramework",
        ]
        + additionalArguments
        try await executor.execute(arguments)
    }

    private func buildCreateXCFrameworkArguments(sdks: Set<SDK>, debugSymbols: [AbsolutePath]?, outputPath: AbsolutePath) throws -> [String] {
        let frameworksArguments: [String] = try sdks.reduce([]) { arguments, sdk in
            let path = try frameworkPath(target: buildProduct.target, of: sdk)
            return arguments + ["-framework", path.pathString]
        }

        let debugSymbolsArguments: [String] = debugSymbols?.reduce(into: []) { arguments, path in
            arguments.append(contentsOf: ["-debug-symbols", path.pathString])
        } ?? []

        let outputPathArguments: [String] = ["-output", outputPath.pathString]

        // Default behavior, this command requires swiftinterface. If they don't exist, `-allow-internal-distribution` must be required.
        let additionalFlags = buildOptions.enableLibraryEvolution ? [] : ["-allow-internal-distribution"]
        return frameworksArguments + debugSymbolsArguments + outputPathArguments + additionalFlags
    }
}

private struct XCBuildOutputDecoder: ErrorDecoder {
    private let jsonDecoder = JSONDecoder()

    func decode(_ result: ExecutorResult) throws -> String? {
        let lines = try result.unwrapOutput().split(separator: "\n")
            .map(String.init)
        return lines.compactMap { line -> String? in
            if let info = try? jsonDecoder.decode(XCBuildErrorInfo.self, from: line), !info.isIgnored {
                return info.message ?? info.data
            }
            return nil
        }
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

private let ignoredKind = ["didUpdateProgress"]

private struct XCBuildErrorInfo: Decodable {
    var kind: String?
    var result: String?
    var error: String?
    var message: String?
    var data: String?

    fileprivate var isIgnored: Bool {
        if let kind {
            return ignoredKind.contains(kind)
        }
        return false
    }
}
