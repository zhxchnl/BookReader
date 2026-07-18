import Foundation
import Combine

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showingImporter = false
    @Published var selectedBook: Book?

    private let database = DatabaseManager.shared
    private let fileImportService = FileImportService()
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadBooks()
    }

    func loadBooks() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let loadedBooks = try database.fetchAllBooks()
                self.books = loadedBooks.map { book in
                    var book = book
                    book.isFileMissing = !BookStorage.fileExists(for: book.filePath)
                    return book
                }
            } catch {
                self.errorMessage = "加载书架失败: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }

    func importBook(from url: URL) {
        fileImportService.importFile(from: url) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let book):
                    do {
                        // 如果数据库里已经有同文件名的旧书(可能文件丢失后用户重导),
                        // 就把旧书的 id 和阅读进度合并到新书,保留阅读历史。
                        if let merged = try self.database.mergeReimportedBook(book) {
                            print("[LibraryViewModel] 重新导入的书匹配到旧记录,已合并: \(merged.title)")
                        } else {
                            try self.database.saveBook(book)
                        }
                        self.loadBooks()
                    } catch {
                        self.errorMessage = "保存书籍失败: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func deleteBook(_ book: Book) {
        Task {
            do {
                try database.deleteBook(byId: book.id)

                let absolutePath = BookStorage.absoluteURL(for: book.filePath).path
                try? FileManager.default.removeItem(atPath: absolutePath)

                loadBooks()
            } catch {
                errorMessage = "删除书籍失败: \(error.localizedDescription)"
            }
        }
    }

    func updateBookProgress(_ book: Book, progress: Double) {
        Task {
            do {
                try database.updateProgress(bookId: book.id, progress: progress)
            } catch {
                print("Update progress failed: \(error)")
            }
        }
    }

    func refreshBook(_ book: Book) {
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
        }
    }
}