import Foundation

/// Finite retained Book projection. URL/source identities are supplied by the caller or search
/// result; these values never create App UUIDs or imply a Room/BookStore mapping.
public struct LegadoOriginalBook: Codable, Sendable, Equatable {
    public let bookURL: String
    public let origin: String
    public var name = ""
    public var author = ""
    public var tocURL = ""
    public var kind: String?
    public var wordCount: String?
    /// Raw JSON string map, matching the original entity's variable field.
    public var variable: String?
    public var infoHTML: String?
    public var tocHTML: String?
    public var originName = ""
    public var originOrder: Int32 = 0
    public var type: Int32 = 8
    public var coverURL: String?
    public var intro: String?
    public var latestChapterTitle: String?
    public var latestChapterTime: Int64?
    public var lastCheckTime: Int64?
    public var lastCheckCount: Int32 = 0
    public var totalChapterNum: Int32 = 0
    public var durChapterTitle: String?
    public var durChapterIndex: Int32 = 0
    public var durChapterPos: Int32?
    public var durChapterTime: Int64?
    public var order: Int32?
    public var imageStyle: String?
    public var reverseToc = false

    public init(bookURL: String, origin: String, name: String = "", author: String = "", tocURL: String = "") {
        self.bookURL = bookURL; self.origin = origin; self.name = name; self.author = author; self.tocURL = tocURL
    }
    private enum CodingKeys: String, CodingKey {
        case bookURL = "bookUrl", tocURL = "tocUrl", coverURL = "coverUrl", infoHTML = "infoHtml", tocHTML = "tocHtml"
        case origin, name, author, kind, wordCount, variable, originName, originOrder, type, intro
        case latestChapterTitle, latestChapterTime, lastCheckTime, lastCheckCount, totalChapterNum, durChapterTitle, durChapterIndex, durChapterPos, durChapterTime, order, imageStyle, reverseToc
    }
}

/// Original URL/index identity and rule metadata only. App chapter identity and save generation
/// remain with the existing reader pipeline.
public struct LegadoOriginalChapter: Codable, Sendable, Equatable {
    public let bookURL: String
    public let url: String
    public let index: Int32
    public var title: String
    public var baseURL: String
    public var isVolume = false
    public var isVip = false
    public var isPay = false
    public var resourceURL: String?
    public var tag: String?
    public var wordCount: String?
    public var start: Int64?
    public var end: Int64?
    public var startFragmentId: String?
    public var endFragmentId: String?
    public var variable: String?
    public var imgURL: String?
    public var titleMD5: String?

    public init(bookURL: String, url: String, index: Int32, title: String, baseURL: String) {
        self.bookURL = bookURL; self.url = url; self.index = index; self.title = title; self.baseURL = baseURL
    }
    private enum CodingKeys: String, CodingKey {
        case bookURL = "bookUrl", baseURL = "baseUrl", resourceURL = "resourceUrl", imgURL = "imgUrl"
        case url, index, title, isVolume, isVip, isPay, tag, wordCount, start, end, startFragmentId, endFragmentId, variable, titleMD5
    }
}

public struct LegadoOriginalSearchResult: Codable, Sendable, Equatable {
    public let books: [LegadoOriginalBook]
}
public struct LegadoOriginalDetailsResult: Codable, Sendable, Equatable {
    public let book: LegadoOriginalBook
}
public struct LegadoOriginalChaptersResult: Codable, Sendable, Equatable {
    public let book: LegadoOriginalBook
    public let chapters: [LegadoOriginalChapter]
}
public struct LegadoOriginalContentResult: Codable, Sendable, Equatable {
    public let book: LegadoOriginalBook
    public let chapter: LegadoOriginalChapter
    public let content: String
}

internal struct OriginalBusinessEnvelope<Value: Decodable>: Decodable { let result: Value }
internal struct OriginalSearchRequest: Encodable, Sendable {
    let key: String; let page: Int32?; let timeoutMs: Int64
    private enum CodingKeys: String, CodingKey { case key, page, timeoutMs }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key); try values.encode(timeoutMs, forKey: .timeoutMs)
        if let page { try values.encode(page, forKey: .page) } else { try values.encodeNil(forKey: .page) }
    }
}
internal struct OriginalDetailsRequest: Encodable, Sendable {
    let book: LegadoOriginalBook; let canReName: Bool; let timeoutMs: Int64
}
internal struct OriginalChaptersRequest: Encodable, Sendable {
    let book: LegadoOriginalBook; let runPreUpdateJs: Bool; let isFromBookInfo: Bool; let timeoutMs: Int64
}
internal struct OriginalContentRequest: Encodable, Sendable {
    let book: LegadoOriginalBook; let chapter: LegadoOriginalChapter; let nextChapterUrl: String?; let timeoutMs: Int64
    let needSave = false
}

/// Snapshot of the explicitly opened original exploration context. This is
/// business state only, never its native backing identity or a cache grant.
public struct LegadoOriginalExploreContextResult: Codable, Sendable, Equatable {
    public let infoMap: [String: String]?
    public let needSave: Bool
    public let result: String?
}
internal struct OriginalExploreRequest: Encodable, Sendable {
    let url: String; let page: Int32?; let timeoutMs: Int64
    private enum CodingKeys: String, CodingKey { case url, page, timeoutMs }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(url, forKey: .url); try values.encode(timeoutMs, forKey: .timeoutMs)
        if let page { try values.encode(page, forKey: .page) } else { try values.encodeNil(forKey: .page) }
    }
}
internal struct OriginalExploreContextRequest: Encodable, Sendable {
    let action: String; let script: String?; let timeoutMs: Int64
}

/// Original getContentBatchAwait result: chapters not marked saved, never inferred bodies.
public struct LegadoOriginalContentBatchResult: Codable, Sendable, Equatable {
    public let book: LegadoOriginalBook
    public let missingChapters: [LegadoOriginalChapter]
    public init(book: LegadoOriginalBook, missingChapters: [LegadoOriginalChapter]) {
        self.book = book; self.missingChapters = missingChapters
    }
}
internal struct OriginalContentBatchRequest: Encodable, Sendable {
    let book: LegadoOriginalBook
    let chapters: [LegadoOriginalChapter]
    let timeoutMs: Int64
}

/// A notification result, never an adoption or body-save grant. Effects report only
/// the actual Host acknowledgements retained by this invocation.
public struct LegadoOriginalBookCallbackResult: Codable, Sendable, Equatable {
    public let executed: Bool
}
internal struct OriginalBookCallbackRequest: Encodable, Sendable {
    let event: String
    let book: LegadoOriginalBook
    let chapter: LegadoOriginalChapter?
    let result: String?
    let timeoutMs: Int64
}

/// Original callBackSource has no book/chapter/result entity and no adoption.
public struct LegadoOriginalSourceCallbackResult: Codable, Sendable, Equatable {
    public let executed: Bool
}
internal struct OriginalSourceCallbackRequest: Encodable, Sendable {
    let event: String
    let timeoutMs: Int64
}

/// Immutable terminal UI facts. Emission does not assert UI application or persistence.
public struct LegadoOriginalLoginUIEntry: Codable, Sendable, Equatable {
    public let key: String
    public let value: String?
    public init(key: String, value: String?) { self.key = key; self.value = value }
}
public struct LegadoOriginalLoginUIEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case updateData, render }
    public let taskID: String
    public let sequence: Int
    public let kind: Kind
    /// nil is the original null reset; [] is a nonnull empty Map.
    public let entries: [LegadoOriginalLoginUIEntry]?
    public let deltaUp: Bool?
    public init(taskID: String, sequence: Int, kind: Kind,
                entries: [LegadoOriginalLoginUIEntry]? = nil, deltaUp: Bool? = nil) {
        self.taskID = taskID; self.sequence = sequence; self.kind = kind
        self.entries = entries; self.deltaUp = deltaUp
    }
    enum CodingKeys: String, CodingKey { case taskID = "taskId", sequence, kind, entries, deltaUp }
}
/// An additional terminal error, separate from payloads and diagnostic output.
public struct LegadoRuntimeFailureDetail: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public struct LegadoOriginalFormLoginResult: Codable, Sendable, Equatable {
    public let credentialsStored: Bool
    public let credentialsCleared: Bool
    public let executed: Bool
    public let loginUIEvents: [LegadoOriginalLoginUIEvent]?
}
internal struct OriginalFormLoginRequest: Encodable, Sendable {
    let credentials: [String: String]
    let timeoutMs: Int64
}

/// Original RowUi/GSON projection, preserving source order and nullable fields.
public struct LegadoOriginalLoginUIRow: Codable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let action: String?
    public let chars: [String?]?
    public let defaultValue: String?
    public let viewName: String?
    public let style: LegadoOriginalLoginUIStyle?
    enum CodingKeys: String, CodingKey {
        case name, type, action, chars, viewName, style
        case defaultValue = "default"
    }
}
public struct LegadoOriginalLoginUIStyle: Codable, Sendable, Equatable {
    public let cols: Int?
    public let rows: Int?
    public let layout_flexBasisPercent: Double?
    public let layout_flexGrow: Double?
    public let layout_wrapBefore: Bool?
    public let layout_justifySelf: String?
}
public struct LegadoOriginalLoginUIResult: Codable, Sendable, Equatable {
    public let rows: [LegadoOriginalLoginUIRow]
    public let labels: [String]
    public let values: [String: String]
    public let dynamic: Bool
    /// Original toggle click closures retain their successful builder name even
    /// when a later upLoginData callback changes the visible caption.
    public let toggleActionLabels: [String?]?
    /// The original null-result branch appends "null" after the toggle value,
    /// independently of its usual right-aligned caption ordering.
    public let toggleLabelSuffixes: [Bool]?
    public let workingMapChanged: Bool?
}
internal struct OriginalLoginUIRequest: Encodable, Sendable {
    let values: [String: String]?
    let evaluationValues: [String: String]?
    let timeoutMs: Int64
}

public struct LegadoOriginalLoginActionResult: Codable, Sendable, Equatable {
    public let executed: Bool
    public let loginUIEvents: [LegadoOriginalLoginUIEvent]?
}
internal struct OriginalLoginActionRequest: Encodable, Sendable {
    let action: String?
    let credentials: [String: String]
    let isLongClick: Bool
    let timeoutMs: Int64
}
