import SwiftUI

@main
struct BookReaderApp: App {
    @StateObject private var libraryViewModel: LibraryViewModel

    init() {
        // 启动时一次性把数据库里的老绝对路径迁到新相对路径,避免重装后书架里的书都打不开。
        DatabaseManager.shared.migrateLegacyAbsolutePaths()
        // 让 Books 目录跟着 iCloud 备份走,以后重装也能保留文件。
        BookStorage.enableiCloudBackupForBooksDirectory()

        _libraryViewModel = StateObject(wrappedValue: LibraryViewModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryViewModel)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gear")
                }
        }
        .tint(.blue)
    }
}