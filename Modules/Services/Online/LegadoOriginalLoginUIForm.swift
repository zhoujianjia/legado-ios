import Foundation
import LegadoRuntime

struct LegadoOriginalLoginUIForm: Sendable {
    let fields: [LoginField]
    let labels: [String: String]
    let values: [String: String]

    init(_ reply: LegadoOriginalLoginUIResult) throws {
        guard reply.rows.count == reply.labels.count else {
            throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original login UI label count differs")
        }
        var mapped: [LoginField] = []
        var resolved: [String: String] = [:]
        for (index, row) in reply.rows.enumerated() {
            // The locked legacy builder has no label/unknown-type branch.
            // Keep the original DTO row, omit its UI node and do not invent input.
            guard let type = LoginField.LoginFieldType(rawValue: row.type) else { continue }
            let style = row.style.map { LoginFieldStyle(cols: $0.cols, rows: $0.rows,
                basisPercent: $0.layout_flexBasisPercent, flexGrow: $0.layout_flexGrow,
                wrapBefore: $0.layout_wrapBefore ?? false, justifySelf: $0.layout_justifySelf) }
            let options = row.chars?.compactMap { $0 }
                ?? (type == .select ? ["chars", "is null"] : type == .toggle ? ["chars is null"] : [])
            var field = LoginField(name: row.name, type: type, action: row.action,
                options: options, defaultValue: row.defaultValue,
                style: style, viewName: row.viewName)
            field.originalRowID = "original-row-\(index)"
            mapped.append(field)
            resolved[field.id] = reply.labels[index]
        }
        fields = mapped; labels = resolved; values = reply.values
    }
}
