import Foundation
import PDFKit
import ZIPFoundation

protocol BookParserProtocol {
    func parse() throws -> ParsedBook
}

struct ParsedBook {
    var title: String
    var author: String
    var chapters: [Chapter]
    var coverImage: Data?
}

struct Chapter: Identifiable {
    let id: UUID
    var title: String
    var content: String

    init(id: UUID = UUID(), title: String, content: String) {
        self.id = id
        self.title = title
        self.content = content
    }
}

final class BookParserService {
    static let shared = BookParserService()

    private init() {}

    func parseBook(at path: String, format: BookFormat) throws -> ParsedBook {
        switch format {
        case .txt:
            return try parseTxt(at: path)
        case .epub:
            return try parseEpub(at: path)
        case .pdf:
            return try parsePdf(at: path)
        }
    }

    private func parseTxt(at path: String) throws -> ParsedBook {
        let url = URL(fileURLWithPath: path)
        let content = try String(contentsOf: url, encoding: .utf8)

        let cleanedContent = cleanText(content)
        let chapters = splitIntoChapters(cleanedContent)

        return ParsedBook(
            title: url.deletingPathExtension().lastPathComponent,
            author: "未知作者",
            chapters: chapters,
            coverImage: nil
        )
    }

    private func cleanText(_ text: String) -> String {
        var result = text

        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")

        let patterns = [
            "\n{3,}",
            " {2,}"
        ]

        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            result = regex?.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n"
            ) ?? result
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitIntoChapters(_ text: String) -> [Chapter] {
        var chapters: [Chapter] = []

        let chapterPatterns = [
            "^第[一二三四五六七八九十百千零\\d]+章\\s*.+$",
            "^Chapter\\s*\\d+.+$",
            "^第[一二三四五六七八九十百千零\\d]+卷\\s*.+$",
            "^第[一二三四五六七八九十百千零\\d]+节\\s*.+$"
        ]

        let pattern = chapterPatterns.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return [Chapter(title: "全文", content: text)]
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        if matches.isEmpty {
            return [Chapter(title: "全文", content: text)]
        }

        var currentIndex = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }

            if currentIndex < matchRange.lowerBound {
                let content = String(text[currentIndex..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let titleEnd = text.index(matchRange.lowerBound, offsetBy: -1, limitedBy: text.startIndex) ?? text.startIndex
                    let lineStart = text[..<matchRange.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                    let title = String(text[lineStart..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    chapters.append(Chapter(title: title.isEmpty ? "第\(chapters.count + 1)章" : title, content: content))
                }
            }
            currentIndex = matchRange.upperBound
        }

        if currentIndex < text.endIndex {
            let remainingContent = String(text[currentIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingContent.isEmpty {
                chapters.append(Chapter(title: "第\(chapters.count + 1)章", content: remainingContent))
            }
        }

        if chapters.isEmpty {
            chapters.append(Chapter(title: "全文", content: text))
        }

        return chapters
    }

    private func parseEpub(at path: String) throws -> ParsedBook {
        let url = URL(fileURLWithPath: path)

        guard let archive = Archive(url: url, accessMode: .read) else {
            throw BookParseError.invalidFormat
        }

        var title = url.deletingPathExtension().lastPathComponent
        var author = "未知作者"
        var chapters: [Chapter] = []
        var coverImage: Data?

        guard let containerData = extractFile(from: archive, path: "META-INF/container.xml") else {
            return try fallbackEpubParse(url: url, title: title)
        }

        let containerParser = ContainerXMLParser(data: containerData)
        let rootfilePath = containerParser.parse()

        if let rootfilePath = rootfilePath,
           let opfData = extractFile(from: archive, path: rootfilePath) {
            let opfParser = OPFParser(data: opfData, basePath: (rootfilePath as NSString).deletingLastPathComponent)
            let opfResult = opfParser.parse()

            title = opfResult.title ?? title
            author = opfResult.author ?? author
            coverImage = opfResult.coverImage

            for item in opfResult.spineItems {
                if let itemData = extractFile(from: archive, path: item.path) {
                    let chapterContent = parseXHTML(data: itemData)
                    if !chapterContent.isEmpty {
                        chapters.append(Chapter(title: item.title ?? "第\(chapters.count + 1)章", content: chapterContent))
                    }
                }
            }
        }

        if chapters.isEmpty {
            return try fallbackEpubParse(url: url, title: title)
        }

        return ParsedBook(title: title, author: author, chapters: chapters, coverImage: coverImage)
    }

    private func extractFile(from archive: Archive, path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data.isEmpty ? nil : data
    }

    private func fallbackEpubParse(url: URL, title: String) throws -> ParsedBook {
        let content = try String(contentsOf: url, encoding: .utf8)

        let strippedContent = content
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")

        let cleanedContent = cleanText(strippedContent)
        let chapters = splitIntoChapters(cleanedContent)

        return ParsedBook(title: title, author: "未知作者", chapters: chapters, coverImage: nil)
    }

    private func parseXHTML(data: Data) -> String {
        guard let htmlString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .iso8859-1) else {
            return ""
        }

        var content = htmlString

        content = content.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#\\d+;": { (match: String) -> String in
                let digits = match.dropFirst(2).dropLast()
                if let code = Int(digits), let scalar = Unicode.Scalar(code) {
                    return String(Character(scalar))
                }
                return ""
            }
        ]

        for (pattern, replacement) in entities {
            if pattern.hasPrefix("&#") {
                content = content.replacingOccurrences(of: pattern, with: replacement("&#32;"))
            } else {
                content = content.replacingOccurrences(of: pattern, with: replacement as? String ?? "")
            }
        }

        content = content.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parsePdf(at path: String) throws -> ParsedBook {
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else {
            throw BookParseError.loadFailed
        }

        var chapters: [Chapter] = []
        var title = url.deletingPathExtension().lastPathComponent

        if let pdfTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            title = pdfTitle
        }

        let pageCount = document.pageCount
        let chapterSize = max(1, pageCount / 10)

        for i in 0..<pageCount {
            guard let page = document.page(at: i),
                  let pageContent = page.string else { continue }

            let chapterIndex = i / chapterSize
            if i % chapterSize == 0 {
                chapters.append(Chapter(title: "第\(chapterIndex + 1)部分", content: ""))
            }

            if let lastIndex = chapters.indices.last {
                chapters[lastIndex].content += pageContent + "\n"
            }
        }

        chapters = chapters.map { chapter in
            var c = chapter
            c.content = cleanText(c.content)
            return c
        }

        if chapters.isEmpty {
            var fullContent = ""
            for i in 0..<pageCount {
                if let page = document.page(at: i), let content = page.string {
                    fullContent += content + "\n"
                }
            }
            chapters.append(Chapter(title: "全文", content: cleanText(fullContent)))
        }

        return ParsedBook(title: title, author: "未知作者", chapters: chapters, coverImage: nil)
    }
}

enum BookParseError: LocalizedError {
    case invalidFormat
    case loadFailed
    case encodingError

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "无法解析电子书格式"
        case .loadFailed:
            return "无法加载文件"
        case .encodingError:
            return "文件编码错误"
        }
    }
}

class ContainerXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var rootfilePath: String?

    init(data: Data) {
        self.data = data
    }

    func parse() -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return rootfilePath
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile" || elementName == "full-path" {
            rootfilePath = attributeDict["full-path"] ?? attributeDict["path"]
        }
    }
}

class OPFParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let basePath: String
    private var currentElement = ""
    private var currentText = ""
    private var manifest: [String: String] = [:]
    private var spineOrder: [String] = []
    private var title: String?
    private var author: String?
    private var coverImageId: String?
    private var coverImage: Data?

    init(data: Data, basePath: String) {
        self.data = data
        self.basePath = basePath
    }

    func parse() -> (title: String?, author: String?, coverImage: Data?, spineItems: [(path: String, title: String?)]) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        let spineItems: [(path: String, title: String?)] = spineOrder.compactMap { id in
            guard let path = manifest[id] else { return nil }
            let fullPath = basePath.isEmpty ? path : "\(basePath)/\(path)"
            return (fullPath, nil)
        }

        return (title, author, coverImage, spineItems)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "item" {
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
                if attributeDict["properties"] == "cover-image" {
                    coverImageId = id
                }
            }
        } else if elementName == "itemref" {
            if let idref = attributeDict["idref"] {
                spineOrder.append(idref)
            }
        } else if elementName == "meta" {
            if attributeDict["name"] == "cover" {
                coverImageId = attributeDict["content"]
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "dc:title" || elementName == "title" {
            title = text
        } else if elementName == "dc:creator" || elementName == "creator" {
            author = text
        }
    }
}