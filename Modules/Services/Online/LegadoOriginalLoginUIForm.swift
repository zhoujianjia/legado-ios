import Foundation
import LegadoRuntime

struct LegadoOriginalLoginUIForm: Sendable {
    let rows: [LegadoOriginalLoginUIRow]
    let layout: LegadoOriginalLoginUILayout
    let dynamic: Bool
    let workingMapChanged: Bool
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
        let physical = reply.layout ?? .init(names: reply.rows.map(\.name), children:
            reply.rows.enumerated().compactMap { index, row -> LegadoOriginalLoginUIChild? in
                LoginField.LoginFieldType(rawValue: row.type) == nil ? nil
                    : .init(id: "original-row-\(index)", rowIndex: index, row: row)
            })
        guard (reply.layout == nil) == (reply.controlStates == nil),
              physical.names.count <= 4096, physical.children.count <= 4096 else {
            throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original physical layout is incomplete")
        }
        try Self.validateNameBridge(reply.rows.map(\.name) + physical.names
            + physical.children.map { $0.row.name } + Array(reply.values.keys))
        var states: [String: LegadoOriginalLoginUIControlState] = [:]
        for state in reply.controlStates ?? [] {
            guard states[state.id] == nil else {
                throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Duplicate original physical state")
            }
            states[state.id] = state
        }
        if reply.layout != nil, states.count != physical.children.count {
            throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original physical state count differs")
        }
        var mapped: [LoginField] = []
        var resolved: [String: String] = [:]
        var buffers: [String: LegadoOriginalLoginUIControl] = [:]
        for child in physical.children {
            let index = child.rowIndex, row = child.row
            // The locked legacy builder has no label/unknown-type branch.
            // Keep the original DTO row, omit its UI node and do not invent input.
            guard let type = LoginField.LoginFieldType(rawValue: row.type),
                  !child.id.isEmpty, child.id.utf8.count <= 128,
                  child.id.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
                  index >= 0, index < 4096, buffers[child.id] == nil else {
                throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Invalid original physical control")
            }
            let style = row.style.map { LoginFieldStyle(cols: $0.cols, rows: $0.rows,
                basisPercent: $0.layout_flexBasisPercent, flexGrow: $0.layout_flexGrow,
                wrapBefore: $0.layout_wrapBefore ?? false, justifySelf: $0.layout_justifySelf) }
            let options = row.chars?.compactMap { $0 }
                ?? (type == .select ? ["chars", "is null"] : type == .toggle ? ["chars is null"] : [])
            var field = LoginField(name: row.name, type: type, action: row.action,
                options: options, defaultValue: row.defaultValue,
                style: style, viewName: row.viewName)
            field.originalRowID = child.id
            mapped.append(field)
            if reply.layout != nil {
                guard let state = states[child.id] else {
                    throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Missing original physical state")
                }
                if type == .select {
                    guard state.selectedIndex.map({ field.options.indices.contains($0) }) ?? field.options.isEmpty else {
                        throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original selection exceeds retained adapter")
                    }
                }
                resolved[field.id] = state.label
                buffers[field.id] = .init(value: state.value, selectedIndex: state.selectedIndex,
                    cycleValue: state.cycleValue, cycleLabel: state.cycleLabel,
                    listenerMapIsCurrent: state.listenerMapIsCurrent, forceSuffix: state.forceSuffix,
                    displayTextOverride: state.displayTextOverride)
                continue
            }
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
        layout = physical
        controls = buffers
        dynamic = reply.dynamic
        workingMapChanged = reply.workingMapChanged ?? false
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
    var displayTextOverride: String? = nil

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
    var bindingFailure: LegadoRuntimeError? = nil
}

struct LegadoOriginalLoginUIUpdate: Sendable {
    let values: [String: String]
    let controls: [String: LegadoOriginalLoginUIControl]
    let labels: [String: String]
    let changedTextRows: [LoginField]
    let actions: [LegadoOriginalLoginUIListenerAction]
}

extension LegadoOriginalLoginUIForm {
    /// Same form controls, in physical child order; never a credential owner.
    nonisolated static func reuseState(layout: LegadoOriginalLoginUILayout,
        labels: [String: String], controls: [String: LegadoOriginalLoginUIControl]
    ) throws -> LegadoOriginalLoginUIReuseState {
        try SourcePerfTrace.span("legado.original.login.ui.reuse.snapshot",
            "main=\(Thread.isMainThread) controls=\(layout.children.count)") {
            let states = try layout.children.map { child -> LegadoOriginalLoginUIControlState in
                guard let control = controls[child.id], let label = labels[child.id] else {
                    throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original physical snapshot is incomplete")
                }
                return .init(id: child.id, value: control.value, label: label,
                    selectedIndex: control.selectedIndex, cycleValue: control.cycleValue,
                    cycleLabel: control.cycleLabel, listenerMapIsCurrent: control.listenerMapIsCurrent,
                    forceSuffix: control.forceSuffix, displayTextOverride: control.displayTextOverride)
            }
            return .init(layout: layout, controls: states)
        }
    }

    /// Raw text/password rows bind the first physical EditText with the assigned
    /// Android id. A reused different widget is an error at getLoginData time.
    nonisolated static func submissionValues(rows: [LegadoOriginalLoginUIRow],
        layout: LegadoOriginalLoginUILayout, values: [String: String],
        controls: [String: LegadoOriginalLoginUIControl]
    ) throws -> [String: String] {
        try SourcePerfTrace.span("legado.original.login.ui.input.snapshot",
            "main=\(Thread.isMainThread) rows=\(rows.count) controls=\(controls.count)") {
            try validateNameBridge(rows.map(\.name) + layout.children.map { $0.row.name } + Array(values.keys))
            var first: [Int: LegadoOriginalLoginUIChild] = [:]
            for child in layout.children where first[child.rowIndex] == nil { first[child.rowIndex] = child }
            var submitted = values
            for (index, row) in rows.enumerated() where row.type == "text" || row.type == "password" {
                guard let child = first[index], child.row.type == "text" || child.row.type == "password",
                      let control = controls[child.id] else {
                    throw LegadoRuntimeError(code: "UI_BINDING_ERROR", message: "Original login row cannot bind its physical input")
                }
                submitted[row.name] = control.value
            }
            return submitted
        }
    }

    /// Locked callbacks dispatch by physical View class, then (TextView only)
    /// latest raw type. Reused listeners retain their old name/options/actions.
    nonisolated static func applying(entries: [LegadoOriginalLoginUIEntry]?,
        rows: [LegadoOriginalLoginUIRow], fields: [LoginField], labels: [String: String],
        values: [String: String], controls: [String: LegadoOriginalLoginUIControl],
        layout: LegadoOriginalLoginUILayout? = nil
    ) throws -> LegadoOriginalLoginUIUpdate {
        try validateNameBridge(rows.map(\.name) + (layout?.names ?? [])
            + (layout?.children.map { $0.row.name } ?? []) + Array(values.keys) + (entries?.map(\.key) ?? []))
        var map = values, edited = controls, captions = labels
        var changedText: [LoginField] = [], actions: [LegadoOriginalLoginUIListenerAction] = []
        let byID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        var assigned: [Int: LoginField] = [:]
        if let layout {
            for child in layout.children where assigned[child.rowIndex] == nil { assigned[child.rowIndex] = byID[child.id] }
        } else {
            for index in rows.indices { assigned[index] = byID["original-row-\(index)"] }
        }
        var firstName: [[UInt16]: Int] = [:]
        for (index, name) in (layout?.names ?? rows.map(\.name)).enumerated() where firstName[Array(name.utf16)] == nil {
            firstName[Array(name.utf16)] = index
        }
        func rawChars(_ row: LegadoOriginalLoginUIRow, toggle: Bool = false) -> [String] {
            row.chars?.compactMap { $0 } ?? (toggle ? ["chars is null"] : ["chars", "is null"])
        }
        func updateText(_ field: LoginField, _ value: String) {
            if edited[field.id]?.value.utf16.elementsEqual(value.utf16) != true { changedText.append(field) }
            edited[field.id] = .init(value: value)
        }
        func updateSelect(_ field: LoginField, row: LegadoOriginalLoginUIRow, value: String?) -> Bool {
            guard !field.options.isEmpty else { return false }
            let desired = value.flatMap { value in rawChars(row).firstIndex { $0.utf16.elementsEqual(value.utf16) } } ?? -1
            let index = min(max(desired, 0), field.options.count - 1)
            let changed = edited[field.id]?.selectedIndex != index
            var control = edited[field.id] ?? .init(value: "")
            control.value = field.options[index]; control.selectedIndex = index; edited[field.id] = control
            return changed
        }
        func action(_ field: LoginField) {
            guard field.action != nil else { return }
            do {
                let credentials: [String: String]
                if let layout { credentials = try submissionValues(rows: rows, layout: layout, values: map, controls: edited) }
                else { credentials = submissionValues(fields: fields, values: map, controls: edited) }
                actions.append(.init(field: field, credentials: credentials))
            } catch {
                // Keep earlier control/Map updates even when the listener's later
                // getLoginData cannot bind a reused widget. Never run an empty substitute.
                actions.append(.init(field: field, credentials: [:], bindingFailure:
                    (error as? LegadoRuntimeError) ?? .init(code: "STATE_IO", message: "Original input snapshot failed")))
            }
        }
        func updateTextView(_ field: LoginField, row: LegadoOriginalLoginUIRow,
            value: String?, output: inout [String: String]) {
            var control = edited[field.id] ?? .init(value: "")
            if row.type == "button" {
                let text = value ?? row.viewName ?? row.name; captions[field.id] = text
                control.displayTextOverride = field.type == .toggle ? text : nil
            } else if row.type == "toggle" {
                let char = value ?? rawChars(row, toggle: true).first ?? ""
                output[row.name] = char
                let name = row.viewName ?? row.name; captions[field.id] = name
                control.value = char; control.forceSuffix = false
                control.displayTextOverride = row.style?.layout_justifySelf == "right" ? name + char : char + name
            }
            edited[field.id] = control
        }
        if let entries {
            for entry in entries {
                guard let index = firstName[Array(entry.key.utf16)] else { map[entry.key] = entry.value ?? ""; continue }
                guard rows.indices.contains(index), let field = assigned[index] else { continue }
                let row = rows[index], value = entry.value ?? row.defaultValue
                switch field.type {
                case .text, .password:
                    let text = value ?? ""; map[row.name] = text; updateText(field, text)
                case .button, .toggle: updateTextView(field, row: row, value: value, output: &map)
                case .select:
                    if updateSelect(field, row: row, value: value) {
                        if edited[field.id]?.listenerMapIsCurrent == true { map[field.name] = edited[field.id]?.value ?? "" }
                        action(field)
                    }
                }
            }
        } else {
            var replacement: [String: String] = [:], selected: [LoginField] = []
            // All existing listener closures captured the replaced Map, even
            // those whose stale assigned ids no longer match a raw row.
            for field in fields where field.type == .select || field.type == .toggle { edited[field.id]?.listenerMapIsCurrent = false }
            for (index, row) in rows.enumerated() {
                guard let field = assigned[index] else { continue }
                switch field.type {
                case .text, .password:
                    let text = row.defaultValue ?? ""; replacement[row.name] = text; updateText(field, text)
                case .button, .toggle: updateTextView(field, row: row, value: row.defaultValue, output: &replacement)
                case .select:
                    replacement[row.name] = row.defaultValue ?? rawChars(row).first ?? ""
                    if updateSelect(field, row: row, value: row.defaultValue) { selected.append(field) }
                }
            }
            map = replacement
            for field in selected { action(field) }
        }
        return .init(values: map, controls: edited, labels: captions, changedTextRows: changedText, actions: actions)
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

/// Locked dialog hasChange is semantic: callbacks/default-selection can mark it
/// even when Map bytes are equal; text-control edits alone never mark it.
struct LegadoOriginalLoginUIDismissState: Sendable {
    private(set) var hasChange = false
    private(set) var oKToClose = false
    private(set) var revision: UInt64 = 0
    var shouldPersist: Bool { hasChange && !oKToClose }

    mutating func markChanged() { hasChange = true; revision &+= 1 }
    mutating func acceptedOK() { oKToClose = true }
    mutating func requestedRender(dynamic: Bool) { if dynamic { markChanged() } }
    mutating func rendered(workingMapChanged: Bool) { if workingMapChanged { markChanged() } }
    /// Only the receipt of the exact frozen working Map can acknowledge it.
    @discardableResult mutating func acknowledge(revision savedRevision: UInt64) -> Bool {
        guard shouldPersist, revision == savedRevision else { return false }
        hasChange = false
        return true
    }
}
