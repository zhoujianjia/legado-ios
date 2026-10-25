import CoreFoundation
import Foundation

/// Typed values decoded from bounded, untrusted DER. Neither this decoder nor
/// XML conversion establishes a signature or provisioning authorization.
/// Uses the CMS reader's existing canonical TLV parser; no private Apple API.
enum SelfRenewalDERPropertyList {
    indirect enum Value: Sendable, Equatable {
        case dictionary([String: Value]), array([Value]), string(String), data(Data)
        case integer(Int64), boolean(Bool), date(Date), null
    }
    enum Failure: Error, Sendable, Equatable {
        case sizeLimit, unsupportedValue, malformedValue, duplicateKey, invalidDate
    }
    enum Limits {
        static let bytes = 1_048_576
        static let nodes = 4_096
        static let depth = 16
        static let children = 256
    }
    private typealias CMS = SelfRenewalCMSVerifier
    private typealias DER = CMS.SignedAttribute.Value

    static func decode(_ data: Data) throws -> Value {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Limits.bytes else { throw Failure.sizeLimit }
        let root = try CMS.parseDER(data)
        var nodes = 0
        return try decode(root, depth: 0, nodes: &nodes)
    }

    static func decodeXMLPropertyList(_ data: Data) throws -> Value {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Limits.bytes else { throw Failure.sizeLimit }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw Failure.malformedValue }
        var nodes = 0
        return try convert(object, depth: 0, nodes: &nodes)
    }

    private static func consume(depth: Int, nodes: inout Int) throws {
        try Task.checkCancellation()
        nodes += 1
        guard depth <= Limits.depth, nodes <= Limits.nodes else { throw Failure.sizeLimit }
    }
    private static func decode(_ value: DER, depth: Int, nodes: inout Int) throws -> Value {
        try consume(depth: depth, nodes: &nodes)
        switch value.tag {
        case 0x31: return try dictionary(value, depth: depth, nodes: &nodes)
        case 0x30:
            return .array(try CMS.children(of: value).map { try decode($0, depth: depth + 1, nodes: &nodes) })
        case 0x70:
            // TN3125's application-tag16 versioned CoreEntitlements envelope.
            let fields = try CMS.children(of: value)
            guard fields.count == 2, fields[0].tag == 0x02, fields[0].body == Data([1]),
                  fields[1].tag == 0xb0 else { throw Failure.unsupportedValue }
            return try dictionary(fields[1], depth: depth + 1, nodes: &nodes)
        case 0x0c, 0x12:
            guard let text = String(data: value.body, encoding: .utf8) else { throw Failure.malformedValue }
            return .string(text)
        case 0x04: return .data(value.body)
        case 0x01:
            guard value.body == Data([0]) || value.body == Data([0xff]) else { throw Failure.malformedValue }
            return .boolean(value.body == Data([0xff]))
        case 0x02:
            guard !value.body.isEmpty, value.body.count <= 8 else { throw Failure.unsupportedValue }
            var bits: UInt64 = value.body.first! & 0x80 == 0 ? 0 : UInt64.max
            for byte in value.body { bits = (bits << 8) | UInt64(byte) }
            return .integer(Int64(bitPattern: bits))
        case 0x17, 0x18: return .date(try date(value.body, generalized: value.tag == 0x18))
        case 0x05:
            guard value.body.isEmpty else { throw Failure.malformedValue }
            return .null
        default: throw Failure.unsupportedValue
        }
    }
    private static func dictionary(_ value: DER, depth: Int, nodes: inout Int) throws -> Value {
        var result: [String: Value] = [:]
        for pair in try CMS.children(of: value) {
            try consume(depth: depth + 1, nodes: &nodes)
            guard pair.tag == 0x30 else { throw Failure.malformedValue }
            let fields = try CMS.children(of: pair)
            guard fields.count == 2, fields[0].tag == 0x0c,
                  let key = String(data: fields[0].body, encoding: .utf8) else { throw Failure.malformedValue }
            guard result[key] == nil else { throw Failure.duplicateKey }
            result[key] = try decode(fields[1], depth: depth + 1, nodes: &nodes)
        }
        return .dictionary(result)
    }
    private static func convert(_ value: Any, depth: Int, nodes: inout Int) throws -> Value {
        try consume(depth: depth, nodes: &nodes)
        if let values = value as? [String: Any] {
            guard values.count <= Limits.children else { throw Failure.sizeLimit }
            var result: [String: Value] = [:]
            for (key, item) in values { result[key] = try convert(item, depth: depth + 1, nodes: &nodes) }
            return .dictionary(result)
        }
        if let values = value as? [Any] {
            guard values.count <= Limits.children else { throw Failure.sizeLimit }
            return .array(try values.map { try convert($0, depth: depth + 1, nodes: &nodes) })
        }
        if let text = value as? String { return .string(text) }
        if let bytes = value as? Data { return .data(bytes) }
        if let date = value as? Date, date.timeIntervalSince1970.isFinite { return .date(date) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            guard String(cString: number.objCType) != "d", String(cString: number.objCType) != "f",
                  number.compare(NSNumber(value: Int64.min)) != .orderedAscending,
                  number.compare(NSNumber(value: Int64.max)) != .orderedDescending else { throw Failure.unsupportedValue }
            return .integer(number.int64Value)
        }
        if value is NSNull { return .null }
        throw Failure.unsupportedValue
    }
    private static func date(_ data: Data, generalized: Bool) throws -> Date {
        let bytes = Array(data)
        let yearBytes = generalized ? 4 : 2
        let whole = yearBytes + 10
        guard bytes.count >= whole + 1, bytes.last == 0x5a else { throw Failure.invalidDate }
        func number(_ start: Int, _ count: Int) throws -> Int {
            guard start >= 0, start + count <= bytes.count else { throw Failure.invalidDate }
            var result = 0
            for byte in bytes[start..<(start + count)] {
                guard (48...57).contains(byte) else { throw Failure.invalidDate }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }
        var year = try number(0, yearBytes)
        if !generalized { year += year < 50 ? 2000 : 1900 }
        let month = try number(yearBytes, 2), day = try number(yearBytes + 2, 2)
        let hour = try number(yearBytes + 4, 2), minute = try number(yearBytes + 6, 2), second = try number(yearBytes + 8, 2)
        guard year >= 1, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { throw Failure.invalidDate }
        var fraction: Double = 0
        if bytes.count != whole + 1 {
            guard generalized, bytes.count <= whole + 11, bytes[whole] == 0x2e,
                  bytes.count >= whole + 3, bytes[bytes.count - 2] != 48 else { throw Failure.invalidDate }
            var scale: Double = 1
            for byte in bytes[(whole + 1)..<(bytes.count - 1)] {
                guard (48...57).contains(byte) else { throw Failure.invalidDate }
                scale *= 10; fraction += Double(byte - 48) / scale
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let value = calendar.date(from: components) else { throw Failure.invalidDate }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else { throw Failure.invalidDate }
        return value.addingTimeInterval(fraction)
    }
}
