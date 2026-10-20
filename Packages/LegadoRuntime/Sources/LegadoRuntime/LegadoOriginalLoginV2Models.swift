import Foundation

/// Version2 is a distinct original protocol, never a legacy RowUi projection.
/// State remains JSON text so source-owned JSON is not aliased by Swift Maps.
public struct LegadoOriginalLoginV2Row: Codable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let key: String?
    public let hint: String?
    public let value: String?
    /// Original GSON accepts null adapter entries. Keep them distinct from
    /// an explicit empty option until the actual EditText value is resolved.
    public let options: [String?]?
    public let action: String?
    public let countdown: Int?
    public let style: LegadoOriginalLoginUIStyle?
}
public struct LegadoOriginalLoginV2RenderResult: Codable, Sendable, Equatable {
    public let rows: [LegadoOriginalLoginV2Row]
    public let storedValues: [String: String]
}
public struct LegadoOriginalLoginV2ActionResult: Codable, Sendable, Equatable {
    public let stateJSON: String?
    public let errors: [String: String]?
    public let close: Bool
    /// True only after the explicit returned login object was checked/saved.
    public let loginStored: Bool
    public let unknownKeys: [String]
}
internal struct OriginalLoginV2UIRequest: Encodable, Sendable {
    let stateJSON: String
    let timeoutMs: Int64
}
internal struct OriginalLoginV2ActionRequest: Encodable, Sendable {
    let action: String
    let stateJSON: String
    let form: [String: String]
    let timeoutMs: Int64
}
