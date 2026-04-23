import Foundation
import SwiftUI

enum BookFormat: String, Codable, CaseIterable {
    case txt = "txt"
    case epub = "epub"
    case pdf = "pdf"

    var displayName: String {
        switch self {
        case .txt: return "文本文件"
        case .epub: return "EPUB电子书"
        case .pdf: return "PDF文档"
        }
    }

    var icon: String {
        switch self {
        case .txt: return "doc.text"
        case .epub: return "book"
        case .pdf: return "doc.richtext"
        }
    }
}

struct Book: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var author: String
    var format: BookFormat
    var filePath: String
    var fileSize: Int64
    var coverImageData: Data?
    var currentProgress: Double
    var lastReadDate: Date?
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "未知作者",
        format: BookFormat,
        filePath: String,
        fileSize: Int64 = 0,
        coverImageData: Data? = nil,
        currentProgress: Double = 0,
        lastReadDate: Date? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.filePath = filePath
        self.fileSize = fileSize
        self.coverImageData = coverImageData
        self.currentProgress = currentProgress
        self.lastReadDate = lastReadDate
        self.dateAdded = dateAdded
    }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var formattedProgress: String {
        return "\(Int(currentProgress * 100))%"
    }

    var lastReadDateFormatted: String? {
        guard let date = lastReadDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}