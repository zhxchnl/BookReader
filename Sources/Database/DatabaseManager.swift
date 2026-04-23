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
}

enum DatabaseError: Error {
    case connectionFailed
    case insertFailed
    case fetchFailed
}