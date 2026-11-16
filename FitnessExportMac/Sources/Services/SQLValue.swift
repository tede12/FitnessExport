import Foundation

enum SQLValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case null

    var double: Double? {
        switch self {
        case .number(let value): return value
        case .text(let value): return Double(value)
        case .null: return nil
        }
    }

    var int: Int? { double.map { Int($0) } }

    var string: String? {
        switch self {
        case .text(let value): return value
        case .number(let value): return String(Int(value))
        case .null: return nil
        }
    }

    var bool: Bool { (double ?? 0) != 0 }
}
