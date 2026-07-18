import Foundation
import SQLite

final class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: Connection?

    private let books = Table("books")
    private let id = Expression<String>("id")
    private let title = Expression<String>("title")
    private let author = Expression<String>("author")
    private let format = Expression<String>("format")
    private let filePath = Expression<String>("filePath")
    private let fileSize = Expression<Int64>("fileSize")
    private let coverImageData = Expression<Data?>("coverImageData")
    private let currentProgress = Expression<Double>("currentProgress")
    private let lastReadDate = Expression<Date?>("lastReadDate")
    private let dateAdded = Expression<Date>("dateAdded")

    private init() {
        setupDatabase()
    }

    /// 老版本数据库里写的是绝对路径(沙盒 `/var/mobile/.../<UUID>/Documents/Books/xxx`),
    /// 重装后 `<UUID>` 变化,所有绝对路径全部失效。这里做一次幂等迁移:
    /// 1) 是相对路径的行不动
    /// 2) 是老绝对路径的行,按文件名在新 Books 目录里找回;找到就改写为相对路径,
    ///    找不到则保留记录(进度等元数据仍在),由 UI 提示「文件丢失」
    ///
    /// 返回值:成功恢复的文件名列表(给上层打 log 用)。
    @discardableResult
    func migrateLegacyAbsolutePaths() -> [String] {
        guard let db = db else { return [] }

        var recovered: [String] = []
        var skipped: [String] = []

        do {
            for row in try db.prepare(books) {
                let stored = row[filePath]

                if !BookStorage.isLegacyAbsolutePath(stored) {
                    // 已经是相对路径(以 Books/ 开头)或合理的新格式,跳过
                    continue
                }

                let fileName = BookStorage.fileName(from: stored)
                guard let bookUUID = UUID(uuidString: row[id]) else { continue }

                if let relative = BookStorage.recoverRelativePath(byFileName: fileName) {
                    let target = books.filter(id == bookUUID.uuidString)
                    try db.run(target.update(filePath <- relative))
                    recovered.append(fileName)
                    print("[DatabaseManager] 迁移成功: \(stored) -> \(relative)")
                } else {
                    skipped.append(fileName)
                    print("[DatabaseManager] 迁移失败(文件不存在): \(stored)")
                }
            }
        } catch {
            print("[DatabaseManager] migrateLegacyAbsolutePaths 失败: \(error)")
        }

        if !recovered.isEmpty {
            print("[DatabaseManager] 迁移完成,共恢复 \(recovered.count) 本: \(recovered)")
        }
        if !skipped.isEmpty {
            print("[DatabaseManager] 以下文件未在 Books 目录找到,请让用户重新导入: \(skipped)")
        }
        return recovered
    }

    private func setupDatabase() {
        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dbPath = documentsPath.appendingPathComponent("bookreader.sqlite3").path
            db = try Connection(dbPath)
            createTables()
        } catch {
            print("Database connection failed: \(error)")
        }
    }

    private func createTables() {
        do {
            try db?.run(books.create(ifNotExists: true) { table in
                table.column(id, primaryKey: true)
                table.column(title)
                table.column(author)
                table.column(format)
                table.column(filePath)
                table.column(fileSize)
                table.column(coverImageData)
                table.column(currentProgress)
                table.column(lastReadDate)
                table.column(dateAdded)
            })
        } catch {
            print("Table creation failed: \(error)")
        }
    }

    func saveBook(_ book: Book) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let insert = books.insert(or: .replace,
            id <- book.id.uuidString,
            title <- book.title,
            author <- book.author,
            format <- book.format.rawValue,
            filePath <- book.filePath,
            fileSize <- book.fileSize,
            coverImageData <- book.coverImageData,
            currentProgress <- book.currentProgress,
            lastReadDate <- book.lastReadDate,
            dateAdded <- book.dateAdded
        )

        try db.run(insert)
    }

    func fetchAllBooks() throws -> [Book] {
        guard let db = db else { throw DatabaseError.connectionFailed }

        var result: [Book] = []
        for row in try db.prepare(books.order(lastReadDate.desc, dateAdded.desc)) {
            if let bookId = UUID(uuidString: row[id]),
               let bookFormat = BookFormat(rawValue: row[format]) {
                let book = Book(
                    id: bookId,
                    title: row[title],
                    author: row[author],
                    format: bookFormat,
                    filePath: row[filePath],
                    fileSize: row[fileSize],
                    coverImageData: row[coverImageData],
                    currentProgress: row[currentProgress],
                    lastReadDate: row[lastReadDate],
                    dateAdded: row[dateAdded]
                )
                result.append(book)
            }
        }
        return result
    }

    func fetchBook(byId bookId: UUID) throws -> Book? {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let query = books.filter(id == bookId.uuidString)
        guard let row = try db.pluck(query) else { return nil }

        if let bookFormat = BookFormat(rawValue: row[format]) {
            return Book(
                id: bookId,
                title: row[title],
                author: row[author],
                format: bookFormat,
                filePath: row[filePath],
                fileSize: row[fileSize],
                coverImageData: row[coverImageData],
                currentProgress: row[currentProgress],
                lastReadDate: row[lastReadDate],
                dateAdded: row[dateAdded]
            )
        }
        return nil
    }

    func updateProgress(bookId: UUID, progress: Double) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let book = books.filter(id == bookId.uuidString)
        try db.run(book.update(
            currentProgress <- progress,
            lastReadDate <- Date()
        ))
    }

    func deleteBook(byId bookId: UUID) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let book = books.filter(id == bookId.uuidString)
        try db.run(book.delete())
    }

    /// 在数据库里按文件名(basename,忽略路径前缀)查找已有的书。
    /// 用于:用户重新导入了一本书,想知道它是不是之前丢失的那本。
    func findBookByFileName(_ fileName: String) throws -> Book? {
        guard let db = db else { throw DatabaseError.connectionFailed }
        let suffix = "/" + fileName

        for row in try db.prepare(books) {
            let stored = row[filePath]
            if stored == fileName || stored.hasSuffix(suffix) {
                guard let bookUUID = UUID(uuidString: row[id]),
                      let bookFormat = BookFormat(rawValue: row[format]) else { continue }
                return Book(
                    id: bookUUID,
                    title: row[title],
                    author: row[author],
                    format: bookFormat,
                    filePath: row[filePath],
                    fileSize: row[fileSize],
                    coverImageData: row[coverImageData],
                    currentProgress: row[currentProgress],
                    lastReadDate: row[lastReadDate],
                    dateAdded: row[dateAdded]
                )
            }
        }
        return nil
    }

    /// 把「重新导入后得到的新书」合并到数据库里已有的旧记录(按文件名匹配到的),
    /// 保留旧书的 `id`、阅读进度和 `lastReadDate` 等元数据,同时把新书的 `filePath` 写入。
    ///
    /// 命中条件:`candidate.fileName` 与 DB 中某条记录的文件名 basename 相同。
    /// 返回值:命中后实际写入数据库的「合并后」书籍;未命中返回 nil(调用方应回退到 `saveBook`)。
    @discardableResult
    func mergeReimportedBook(_ newBook: Book) throws -> Book? {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let newFileName = BookStorage.fileName(from: newBook.filePath)
        guard let existing = try findBookByFileName(newFileName) else {
            return nil
        }

        // 命中旧记录:覆盖 id 用旧的,进度等元数据全部沿用旧的,
        // 只把 filePath / fileSize / title 改成新导入的(覆盖同名异书的情况)。
        let merged = Book(
            id: existing.id,
            title: newBook.title,
            author: newBook.author,
            format: newBook.format,
            filePath: newBook.filePath,
            fileSize: newBook.fileSize,
            coverImageData: newBook.coverImageData ?? existing.coverImageData,
            currentProgress: existing.currentProgress,
            lastReadDate: existing.lastReadDate,
            dateAdded: existing.dateAdded
        )

        // 用旧 id 写入 → 走 INSERT OR REPLACE 原地更新,进度等元数据保留
        let insert = books.insert(or: .replace,
            id <- merged.id.uuidString,
            title <- merged.title,
            author <- merged.author,
            format <- merged.format.rawValue,
            filePath <- merged.filePath,
            fileSize <- merged.fileSize,
            coverImageData <- merged.coverImageData,
            currentProgress <- merged.currentProgress,
            lastReadDate <- merged.lastReadDate,
            dateAdded <- merged.dateAdded
        )
        try db.run(insert)

        print("[DatabaseManager] 合并成功: 旧书(\(existing.title), 进度 \(Int(existing.currentProgress * 100))%) 重新激活,新文件 \(newFileName)")
        return merged
    }
}

enum DatabaseError: Error {
    case connectionFailed
    case insertFailed
    case fetchFailed
}