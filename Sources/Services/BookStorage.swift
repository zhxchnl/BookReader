import Foundation

/// 集中处理书籍文件在沙盒中的相对路径 / 绝对路径转换。
///
/// iOS 每次重装都会生成新的沙盒容器 UUID,直接保存绝对路径会导致
/// 「数据库还能读到书、文件却不在原位置」的情况。统一在存数据库时
/// 使用相对 `Documents` 目录的相对路径,使用时再拼接。
enum BookStorage {
    static let booksDirectoryName = "Books"

    /// 沙盒 Documents 目录下「Books」文件夹的绝对路径。
    static var booksDirectoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent(booksDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// 把目标 URL 转成存进数据库的相对路径,例如 `Books/xxx.txt`。
    /// - Parameter absoluteURL: 文件当前的绝对路径。
    /// - Returns: 若在 Books 目录下则返回相对路径,否则原样返回绝对路径(向后兼容)。
    static func relativePath(for absoluteURL: URL) -> String {
        let absolutePath = absoluteURL.standardizedFileURL.path
        let booksPath = booksDirectoryURL.standardizedFileURL.path
        let prefix = booksPath.hasSuffix("/") ? booksPath : booksPath + "/"
        if absolutePath.hasPrefix(prefix) {
            return booksDirectoryName + "/" + String(absolutePath.dropFirst(prefix.count))
        }
        return absolutePath
    }

    /// 把数据库里的路径还原成沙盒中的绝对路径。
    static func absoluteURL(for storedPath: String) -> URL {
        if storedPath.hasPrefix("/") {
            return URL(fileURLWithPath: storedPath)
        }
        if storedPath.hasPrefix(booksDirectoryName + "/") {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documents.appendingPathComponent(storedPath)
        }
        return URL(fileURLWithPath: storedPath)
    }

    /// 判断存储路径对应的文件当前是否还存在。
    static func fileExists(for storedPath: String) -> Bool {
        FileManager.default.fileExists(atPath: absoluteURL(for: storedPath).path)
    }

    /// 判断当前存储的路径是不是「老版本写进去的绝对路径」。
    /// 老绝对路径以 `/` 开头,通常还会包含沙盒容器目录 `Containers/Data/Application/<UUID>/Documents/`。
    static func isLegacyAbsolutePath(_ storedPath: String) -> Bool {
        guard storedPath.hasPrefix("/") else { return false }
        return storedPath.contains("/Documents/") || storedPath.contains("/Books/")
    }

    /// 提取路径里的文件名(处理可能存在的相对/绝对两种形式)。
    static func fileName(from storedPath: String) -> String {
        let trimmed = storedPath.hasSuffix("/") ? String(storedPath.dropLast()) : storedPath
        return (trimmed as NSString).lastPathComponent
    }

    /// 用 `fileName` 在新沙盒的 Books 目录里找一遍。
    /// 命中时返回相对路径(同时把文件复制/移动到 Books 目录里——其实就在 Books 目录中,无需移动);
    /// 没找到就返回 nil。
    static func recoverRelativePath(byFileName fileName: String) -> String? {
        let candidate = booksDirectoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return relativePath(for: candidate)
        }
        return nil
    }

    /// 把 Books 目录的「不参加 iCloud 备份」属性关闭,让书籍文件能在重装时被还原。
    /// `Info.plist` 里的 `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace` 决定
    /// `Documents` 目录本身是否备份;Books 子目录是否被备份,需要显式清掉排除属性。
    static func enableiCloudBackupForBooksDirectory() {
        let directory = booksDirectoryURL
        var url = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = false
        do {
            try url.setResourceValues(resourceValues)
        } catch {
            print("[BookStorage] enableiCloudBackup 失败: \(error)")
        }
    }
}
