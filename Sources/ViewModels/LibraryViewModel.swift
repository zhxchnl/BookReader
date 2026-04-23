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
                self.books = loadedBooks
            } catch {
                self.errorMessage = "加载书架失败: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }

    func importBook(from url: URL) {
        fileImportService.importFile(from: url) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let book):
                    do {
                        try self?.database.saveBook(book)
                        self?.loadBooks()
                    } catch {
                        self?.errorMessage = "保存书籍失败: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func deleteBook(_ book: Book) {
        Task {
            do {
                try database.deleteBook(byId: book.id)

                try? FileManager.default.removeItem(atPath: book.filePath)

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