import SwiftUI

extension Color {
    static let appBackground = Color(UIColor.systemBackground)
    static let appSecondaryBackground = Color(UIColor.secondarySystemBackground)
    static let appGroupedBackground = Color(UIColor.systemGroupedBackground)
    static let appLabel = Color(UIColor.label)
    static let appSecondaryLabel = Color(UIColor.secondaryLabel)
    static let appAccent = Color.accentColor
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func truncated(to length: Int, trailing: String = "...") -> String {
        if count > length {
            return String(prefix(length)) + trailing
        }
        return self
    }
}

extension FileManager {
    var documentsDirectory: URL {
        urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var booksDirectory: URL {
        documentsDirectory.appendingPathComponent("Books", isDirectory: true)
    }

    func createBooksDirectoryIfNeeded() throws {
        if !fileExists(atPath: booksDirectory.path) {
            try createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        }
    }
}