import Foundation

/// A JSON value with lenient accessors. The RVRB specs don't always match what the server sends (a chat message's
/// `userId` is sometimes a number, users have no `role`), so values are read loosely instead of through strict
/// `Codable` types, which failed on the first channel joined. Track objects are kept whole as `JSON` because the
/// server wants the full Spotify object back when this client DJs.
nonisolated enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(parsing data: Data) throws {
        self.init(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    init(any value: Any) {
        switch value {
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSON.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSON.init(any:)))
        default:
            self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): Self.isIntegral(value) ? Int64(value) as Any : value as Any
        case .string(let value): value
        case .array(let value): value.map(\.any)
        case .object(let value): value.mapValues(\.any)
        }
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    /// The value serialised, for sending and logging.
    var text: String {
        (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    subscript(index: Int) -> JSON? {
        if case .array(let array) = self, array.indices.contains(index) { array[index] } else { nil }
    }

    /// Strings as they are; numbers and booleans as text (ids sometimes arrive as numbers).
    var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): Self.isIntegral(value) ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    /// The string, unless it's missing or empty.
    var nonEmptyString: String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var int: Int? {
        guard let double, double.isFinite, abs(double) < 9e18 else { return nil }
        return Int(double)
    }

    var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// `true`, or a number above zero (votes come as 1/0).
    var isOn: Bool {
        bool ?? ((double ?? 0) > 0)
    }

    var array: [JSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    var object: [String: JSON]? {
        if case .object(let value) = self { value } else { nil }
    }

    private static func isIntegral(_ value: Double) -> Bool {
        value.rounded() == value && abs(value) < 1e15
    }
}

nonisolated extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements) { _, last in last }) }
    init(nilLiteral: ()) { self = .null }
}
