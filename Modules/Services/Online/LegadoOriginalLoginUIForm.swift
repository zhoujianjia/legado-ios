import Foundation
import LegadoRuntime

struct LegadoOriginalLoginUIForm: Sendable {
    let rows: [LegadoOriginalLoginUIRow]
    let fields: [LoginField]
    let labels: [String: String]
    let values: [String: String]
    let controls: [String: LegadoOriginalLoginUIControl]

    init(_ reply: LegadoOriginalLoginUIResult) throws {
        guard reply.rows.count == reply.labels.count else {
            throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original login UI label count differs")
        }
        if let names = reply.toggleActionLabels, names.count != reply.rows.count {
            throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original login toggle labels differ")
        }
        if let suffixes = reply.toggleLabelSuffixes, suffixes.count != reply.rows.count {
            throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original login toggle placement differs")
        }
        try Self.validateNameBridge(reply.rows.map(\.name) + Array(reply.values.keys))
        var mapped: [LoginField] = []
        var resolved: [String: String] = [:]
        var buffers: [String: LegadoOriginalLoginUIControl] = [:]
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
            let raw: String
            switch type {
            case .text, .password: raw = reply.values[field.name] ?? field.defaultValue ?? ""
            case .select, .toggle: raw = reply.values[field.name] ?? field.defaultValue ?? field.options.first ?? ""
            case .button: raw = ""
            }
            if type == .select {
                let selected = field.options.firstIndex { $0.utf16.elementsEqual(raw.utf16) }
                    ?? (field.options.isEmpty ? nil : 0)
                buffers[field.id] = .init(value: selected.map { field.options[$0] } ?? "", selectedIndex: selected)
            } else {
                let cycleName: String
                if let names = reply.toggleActionLabels { cycleName = names[index] ?? row.name }
                else { cycleName = row.name }
                buffers[field.id] = .init(value: type == .button ? "" : raw,
                    cycleValue: type == .toggle ? raw : nil,
                    cycleLabel: type == .toggle ? cycleName : nil,
                    forceSuffix: type == .toggle && (reply.toggleLabelSuffixes?[index] ?? false))
            }
        }
        rows = reply.rows; fields = mapped; labels = resolved; values = reply.values
        controls = buffers
    }
}

/// The actual rendered controls are distinct from the dialog's name-keyed Map.
/// Duplicate text rows and unmatched Spinner values must retain that distinction.
struct LegadoOriginalLoginUIControl: Equatable, Sendable {
    var value: String
    var selectedIndex: Int? = nil
    var cycleValue: String? = nil
    var cycleLabel: String? = nil
    var listenerMapIsCurrent = true
    var forceSuffix = false

    nonisolated static func toggleDisplay(value: String, label: String, justifySelf: String?,
        forceSuffix: Bool) -> String {
        !forceSuffix && justifySelf == "right" ? label + value : value + label
    }
}

struct LegadoOriginalLoginUIActionBudget: Sendable {
    private(set) var automaticCount = 0
    mutating func acceptAutomatic() throws {
        guard automaticCount < 128 else {
            throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Original login listener chain exceeded its finite budget")
        }
        automaticCount += 1
    }
}

struct LegadoOriginalLoginUIListenerAction: Sendable {
    let field: LoginField
    let credentials: [String: String]
}

struct LegadoOriginalLoginUIUpdate: Sendable {
    let values: [String: String]
    let controls: [String: LegadoOriginalLoginUIControl]
    let labels: [String: String]
    let changedTextRows: [LoginField]
    let actions: [LegadoOriginalLoginUIListenerAction]
}

extension LegadoOriginalLoginUIForm {
    /// Locked Dialog130–217. This only changes the current form, never credentials.
    nonisolated static func applying(entries: [LegadoOriginalLoginUIEntry]?,
        rows: [LegadoOriginalLoginUIRow], fields: [LoginField], labels: [String: String],
        values: [String: String], controls: [String: LegadoOriginalLoginUIControl]
    ) throws -> LegadoOriginalLoginUIUpdate {
        try validateNameBridge(rows.map(\.name) + Array(values.keys) + (entries?.map(\.key) ?? []))
        var map = values, edited = controls, captions = labels
        var changedText: [LoginField] = [], actions: [LegadoOriginalLoginUIListenerAction] = []
        let byID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        var firstRows: [[UInt16]: Int] = [:]
        for (index, row) in rows.enumerated() where firstRows[Array(row.name.utf16)] == nil {
            firstRows[Array(row.name.utf16)] = index
        }
        func rowField(_ index: Int) -> LoginField? { byID["original-row-\(index)"] }
        func updateText(_ field: LoginField, _ value: String) {
            if edited[field.id]?.value.utf16.elementsEqual(value.utf16) != true { changedText.append(field) }
            edited[field.id] = .init(value: value)
        }
        func updateSelect(_ field: LoginField, _ value: String?) -> Bool {
            let index = value.flatMap { value in field.options.firstIndex { $0.utf16.elementsEqual(value.utf16) } }
                ?? (field.options.isEmpty ? nil : 0)
            let changed = edited[field.id]?.selectedIndex != index
            var control = edited[field.id] ?? .init(value: "")
            control.value = index.map { field.options[$0] } ?? ""; control.selectedIndex = index
            edited[field.id] = control
            return changed && index != nil
        }
        func action(_ field: LoginField) {
            guard field.action != nil else { return }
            actions.append(.init(field: field, credentials: submissionValues(fields: fields,
                values: map, controls: edited)))
        }
        if let entries {
            for entry in entries {
                guard let index = firstRows[Array(entry.key.utf16)] else {
                    map[entry.key] = entry.value ?? ""
                    continue
                }
                // An original unknown/label row has a name but no matching View.
                guard let field = rowField(index) else { continue }
                let row = rows[index], value = entry.value ?? row.defaultValue
                switch field.type {
                case .text, .password:
                    let text = value ?? ""
                    map[field.name] = text; updateText(field, text)
                case .button:
                    captions[field.id] = value ?? row.viewName ?? row.name
                case .toggle:
                    let text = value ?? field.options.first ?? ""
                    map[field.name] = text
                    var control = edited[field.id] ?? .init(value: "")
                    control.value = text; control.forceSuffix = false; edited[field.id] = control
                    captions[field.id] = row.viewName ?? row.name
                case .select:
                    if updateSelect(field, value) {
                        if edited[field.id]?.listenerMapIsCurrent == true {
                            map[field.name] = edited[field.id]?.value ?? ""
                        }
                        action(field)
                    }
                }
            }
        } else {
            var replacement: [String: String] = [:], selected: [LoginField] = []
            for (index, row) in rows.enumerated() {
                guard let field = rowField(index) else { continue }
                switch field.type {
                case .text, .password:
                    let text = row.defaultValue ?? ""
                    replacement[field.name] = text; updateText(field, text)
                case .button:
                    captions[field.id] = row.viewName ?? row.name
                case .toggle:
                    let text = row.defaultValue ?? field.options.first ?? ""
                    replacement[field.name] = text
                    var control = edited[field.id] ?? .init(value: "")
                    control.value = text; control.listenerMapIsCurrent = false; control.forceSuffix = false
                    edited[field.id] = control
                    captions[field.id] = row.viewName ?? row.name
                case .select:
                    replacement[field.name] = row.defaultValue ?? field.options.first ?? ""
                    edited[field.id]?.listenerMapIsCurrent = false
                    if updateSelect(field, row.defaultValue) { selected.append(field) }
                }
            }
            map = replacement
            // Spinner notification observes the completed reset, including the new Map.
            for field in selected { action(field) }
        }
        return .init(values: map, controls: edited, labels: captions,
            changedTextRows: changedText, actions: actions)
    }

    /// Java names use exact UTF16 units. Swift String-keyed Maps cannot express
    /// two distinct Java names that Swift regards as canonically equivalent.
    private nonisolated static func validateNameBridge(_ names: [String]) throws {
        var spellings: [String: [UInt16]] = [:]
        for name in names {
            let units = Array(name.utf16)
            if let previous = spellings[name], previous != units {
                throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY",
                    message: "Original login names cannot be represented by the form Map")
            }
            spellings[name] = units
        }
    }

    nonisolated static func submissionValues(fields: [LoginField], values: [String: String],
        controls: [String: LegadoOriginalLoginUIControl]?) -> [String: String] {
        var submitted = values
        for field in fields where field.type == .text || field.type == .password {
            submitted[field.name] = controls?[field.id]?.value ?? values[field.name] ?? field.defaultValue ?? ""
        }
        return submitted
    }
}
