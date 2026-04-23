import Foundation
import UniformTypeIdentifiers

final class FileImportService: ObservableObject {
    @Published var isImporting = false
    @Published var importedBook: Book?
    @Published var errorMessage: String?

    static let supportedContentTypes: [UTType] = [
        .plainText,
        UTType(filenameExtension: "epub") ?? .data,
        UTType(filenameExtension: "pdf") ?? .data
    ]

    static let supportedExtensions: [String] = ["txt", "epub", "pdf"]

    func importFile(from sourceURL: URL, completion: @escaping (Result<Book, Error>) -> Void) {
        isImporting = true

        guard sourceURL.startAccessingSecurityScopedResource() else {
            DispatchQueue.main.async {
                self.isImporting = false
                self.errorMessage = "无法访问文件"
                completion(.failure(FileImportError.accessDenied))
            }
            return
        }

        defer {
            sourceURL.stopAccessingSecurityScopedResource()
        }

        let fileExtension = sourceURL.pathExtension.lowercased()

        guard Self.supportedExtensions.contains(fileExtension) else {
            DispatchQueue.main.async {
                self.isImporting = false
                self.errorMessage = "不支持的文件格式: \(fileExtension)"
                completion(.failure(FileImportError.unsupportedFormat))
            }
            return
        }

        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let booksDirectory = documentsPath.appendingPathComponent("Books", isDirectory: true)

            try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)

            let fileName = sourceURL.lastPathComponent
            let destinationURL = booksDirectory.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            let bookId = UUID()
            let bookFormat: BookFormat

            switch fileExtension {
            case "txt":
                bookFormat = .txt
            case "epub":
                bookFormat = .epub
            case "pdf":
                bookFormat = .pdf
            default:
                throw FileImportError.unsupportedFormat
            }

            let title = extractTitle(from: sourceURL.deletingPathExtension().lastPathComponent, format: bookFormat)

            let book = Book(
                id: bookId,
                title: title,
                author: "未知作者",
                format: bookFormat,
                filePath: destinationURL.path,
                fileSize: fileSize,
                coverImageData: nil,
                currentProgress: 0,
                dateAdded: Date()
            )

            DispatchQueue.main.async {
                self.isImporting = false
                self.importedBook = book
                completion(.success(book))
            }

        } catch {
            DispatchQueue.main.async {
                self.isImporting = false
                self.errorMessage = error.localizedDescription
                completion(.failure(error))
            }
        }
    }

    private func extractTitle(from fileName: String, format: BookFormat) -> String {
        var title = fileName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let suffixes = ["\(format.rawValue.uppercased())", "txt", "novel", "book", "全本", "完整版"]
        for suffix in suffixes {
            if title.lowercased().hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count + 1))
            }
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未命名书籍" : title
    }
}

enum FileImportError: LocalizedError {
    case accessDenied
    case unsupportedFormat
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "无法访问文件，请检查权限设置"
        case .unsupportedFormat:
            return "不支持的文件格式"
        case .copyFailed:
            return "文件复制失败"
        }
    }
}