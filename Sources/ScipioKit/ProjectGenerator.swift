import Foundation
import Xcodeproj
import TSCBasic
import Basics

struct ProjectGenerator {
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
    }

    struct Result {
        var project: Xcode.Project
        var projectPath: AbsolutePath
    }

    @discardableResult
    func generate(for package: Package) throws -> Result {
        let projectPath = package.projectPath

        let project = try pbxproj(
            xcodeprojPath: projectPath,
            graph: package.graph,
            extraDirs: [],
            extraFiles: [],
            options: .init(useLegacySchemeGenerator: false),
            fileSystem: fileSystem,
            observabilityScope: observabilitySystem.topScope)

        let distributionXCConfigPath = package.workspaceDirectory.appending(component: "Distribution.xcconfig")
        try fileSystem.writeFileContents(distributionXCConfigPath,
                                         string: distributionXCConfigContents)

        let group = createOrGetConfigsGroup(project: project)
        let reference = group.addFileReference (
            path: distributionXCConfigPath.pathString,
            name: distributionXCConfigPath.basename
        )

        for target in project.frameworkTargets {
            target.buildSettings.xcconfigFileRef = reference
        }

        for target in project.frameworkTargets {
            let name = "\(target.name.spm_mangledToC99ExtendedIdentifier())_Info.plist"
            let path = projectPath.appending(RelativePath(name))
            try fileSystem.writeFileContents(path) { stream in
                stream.write(infoPlist)
            }
        }

        try fileSystem.writeFileContents(projectPath.appending(component: "project.pbxproj")) { stream in
            // Serialize the project model we created to a plist, and return
            // its string description.
            if let plist = try? project.generatePlist() {
                let str = "// !$*UTF8*$!\n" + plist.description
                stream.write(str)
            }
        }

        return .init(project: project, projectPath: projectPath)
    }

    private var distributionXCConfigContents: String {
        """
        BUILD_LIBRARY_FOR_DISTRIBUTION = YES
        DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
        """

        //        ENABLE_BITCODE = YES
        //        OTHER_CFLAGS = -fembed-bitcode
    }

    private var infoPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleExecutable</key>
        <string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$(PRODUCT_NAME)</string>
        <key>CFBundlePackageType</key>
        <string>FMWK</string>
        <key>CFBundleShortVersionString</key>
        <string>1.0</string>
        <key>CFBundleSignature</key>
        <string>????</string>
        <key>CFBundleVersion</key>
        <string>$(CURRENT_PROJECT_VERSION)</string>
        <key>NSPrincipalClass</key>
        <string></string>
        </dict>
        </plist>
        """
    }

    private func createOrGetConfigsGroup(project: Xcode.Project) -> Xcode.Group {
        let name = "Configs"

        if let group = project.mainGroup.subitems.lazy.compactMap({ $0 as? Xcode.Group }).first(where: { $0.name == name }) {
            return group
        }

        return project.mainGroup.addGroup(path: "", name: name)
    }
}

extension Xcode.Project {
    fileprivate var frameworkTargets: [Xcode.Target] {
        targets.filter { $0.productType == .framework }
    }
}