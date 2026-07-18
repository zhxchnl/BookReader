import Foundation

struct SearchResult: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let chapterTitle: String
    let matchText: String
    let contextBefore: String
    let contextAfter: String
    /// 摘要前是否还有未展示的原文
    let omitsBefore: Bool
    /// 摘要后是否还有未展示的原文
    let omitsAfter: Bool
    let globalCharacterStart: Int
}
