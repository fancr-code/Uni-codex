import Darwin
import Foundation

enum ManagedPathPolicy {
    private enum ItemKind {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    static func requireSafeAncestors(root: URL, target: URL) throws {
        let rootURL = try lexicalURL(root)
        let targetURL = try lexicalURL(target)
        let rootPath = rootURL.path
        let targetPath = targetURL.path
        let isContained = targetPath == rootPath
            || (rootPath == "/" ? targetPath.hasPrefix("/") : targetPath.hasPrefix(rootPath + "/"))
        guard isContained else {
            throw pathError("managed path escapes its trusted root")
        }

        try requirePhysicalDirectoryChain(rootURL)
        var cursor = rootURL
        let relative = relativeComponents(rootPath: rootPath, targetPath: targetPath)
        for component in relative.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            try requireDirectoryIfPresent(cursor)
        }
    }

    static func ensurePrivateDirectory(root: URL, directory: URL) throws {
        let rootURL = try lexicalURL(root)
        let directoryURL = try lexicalURL(directory)
        try requireSafeAncestors(root: rootURL, target: directoryURL.appendingPathComponent("leaf"))
        guard try itemKind(at: rootURL) == .directory else {
            throw pathError("managed root is not an existing directory")
        }

        var cursor = rootURL
        for component in relativeComponents(rootPath: rootURL.path, targetPath: directoryURL.path) {
            cursor.appendPathComponent(component, isDirectory: true)
            var created = false
            if try itemKind(at: cursor) == nil {
                try FileManager.default.createDirectory(
                    at: cursor,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                created = true
            }
            guard try itemKind(at: cursor) == .directory else {
                throw pathError("managed directory is not a regular directory")
            }
            if created || cursor.path == directoryURL.path {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cursor.path)
            }
        }
    }

    @discardableResult
    static func requireRegularFileIfPresent(root: URL, target: URL) throws -> Bool {
        try requireSafeAncestors(root: root, target: target)
        guard let kind = try itemKind(at: lexicalURL(target)) else { return false }
        guard kind == .regularFile else {
            throw pathError("managed file is not a regular file")
        }
        return true
    }

    static func requireRegularFile(root: URL, target: URL) throws {
        guard try requireRegularFileIfPresent(root: root, target: target) else {
            throw pathError("managed file is missing")
        }
    }

    @discardableResult
    static func requireDirectoryIfPresent(root: URL, target: URL) throws -> Bool {
        try requireSafeAncestors(root: root, target: target)
        guard let kind = try itemKind(at: lexicalURL(target)) else { return false }
        guard kind == .directory else {
            throw pathError("managed directory is not a regular directory")
        }
        return true
    }

    static func requireDirectory(root: URL, target: URL) throws {
        guard try requireDirectoryIfPresent(root: root, target: target) else {
            throw pathError("managed directory is missing")
        }
    }

    private static func requireDirectoryIfPresent(_ url: URL) throws {
        guard let kind = try itemKind(at: url) else { return }
        guard kind == .directory else {
            throw pathError("managed path contains a non-directory or symbolic link: \(url.path)")
        }
    }

    private static func requirePhysicalDirectoryChain(_ directory: URL) throws {
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        try requireDirectoryIfPresent(cursor)
        for component in directory.path.split(separator: "/").map(String.init) {
            cursor.appendPathComponent(component, isDirectory: true)
            try requireDirectoryIfPresent(cursor)
        }
    }

    private static func relativeComponents(rootPath: String, targetPath: String) -> [String] {
        let offset = rootPath == "/" ? 1 : rootPath.count
        return String(targetPath.dropFirst(offset)).split(separator: "/").map(String.init)
    }

    static func lexicalPath(_ url: URL) throws -> String {
        try lexicalURL(url).path
    }

    private static func lexicalURL(_ url: URL) throws -> URL {
        let path = url.path
        guard path.hasPrefix("/") else {
            throw pathError("managed path must be absolute")
        }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else {
                    throw pathError("managed path escapes the filesystem root")
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    private static func itemKind(at url: URL) throws -> ItemKind? {
        var information = stat()
        if Darwin.lstat(url.path, &information) == 0 {
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                return .directory
            case S_IFREG:
                return .regularFile
            case S_IFLNK:
                return .symbolicLink
            default:
                return .other
            }
        }
        if errno == ENOENT {
            return nil
        }
        throw pathError("managed path could not be inspected")
    }

    private static func pathError(_ message: String) -> NSError {
        NSError(
            domain: "CodexOneClickInstaller.ManagedPath",
            code: 65,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
