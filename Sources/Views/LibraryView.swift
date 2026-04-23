import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var viewModel: LibraryViewModel
    @State private var showingImporter = false
    @State private var showingDeleteAlert = false
    @State private var bookToDelete: Book?

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("加载中...")
                } else if viewModel.books.isEmpty {
                    emptyStateView
                } else {
                    bookGridView
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingImporter = true }) {
                        Image(systemName: "plus")
                            .font(.title3)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.plainText, UTType(filenameExtension: "epub") ?? .data, UTType(filenameExtension: "pdf") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("删除书籍", isPresented: $showingDeleteAlert) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    if let book = bookToDelete {
                        viewModel.deleteBook(book)
                    }
                }
            } message: {
                Text("确定要删除《\(bookToDelete?.title ?? "")》吗？此操作不可撤销。")
            }
            .alert("错误", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("书架为空")
                .font(.title2)
                .fontWeight(.semibold)

            Text("点击右上角的 + 按钮导入书籍")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: { showingImporter = true }) {
                Label("导入书籍", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding()
    }

    private var bookGridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(viewModel.books) { book in
                    NavigationLink(destination: ReaderView(book: book).environmentObject(viewModel)) {
                        BookCardView(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            bookToDelete = book
                            showingDeleteAlert = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            viewModel.importBook(from: url)
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

struct BookCardView: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(bookCoverGradient)
                    .aspectRatio(0.7, contentMode: .fit)

                if let coverData = book.coverImageData,
                   let uiImage = UIImage(data: coverData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: book.format.icon)
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.9))

                        Text(book.format.rawValue.uppercased())
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                Text(book.author)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if book.currentProgress > 0 {
                ProgressView(value: book.currentProgress)
                    .tint(.blue)
            }
        }
    }

    private var bookCoverGradient: LinearGradient {
        let colors: [Color] = [
            Color(red: Double.random(in: 0.3...0.6), green: Double.random(in: 0.3...0.6), blue: Double.random(in: 0.5...0.8)),
            Color(red: Double.random(in: 0.4...0.7), green: Double.random(in: 0.3...0.5), blue: Double.random(in: 0.4...0.7))
        ]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

#Preview {
    LibraryView()
        .environmentObject(LibraryViewModel())
}