import Foundation
import CoreFoundation

public extension JSONValue {
    static func from(any value: Any?) -> JSONValue? {
        // NSNumber(0/1) can bridge to Bool even when it is a JSON number.
        // Inspect the Foundation type before Swift's permissive numeric casts.
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        switch value {
        case nil:
            return .null
        case let value as JSONValue:
            return value
        case let value as String:
            return .string(value)
        case let value as Int:
            return .integer(Int64(value))
        case let value as Int64:
            return .integer(value)
        case let value as UInt64:
            guard value <= UInt64(Int64.max) else {
                return nil
            }
            return .integer(Int64(value))
        case let value as Double:
            return .number(value)
        case let value as Float:
            return .number(Double(value))
        case let value as NSNumber:
            let number = value.doubleValue
            if number.rounded() == number,
               number >= Double(Int64.min),
               number <= Double(Int64.max),
               abs(number) <= 9_007_199_254_740_992 {
                return .integer(Int64(number))
            }
            return .number(value.doubleValue)
        case let value as [Any]:
            var array: [JSONValue] = []
            array.reserveCapacity(value.count)
            for element in value {
                guard let converted = JSONValue.from(any: element) else {
                    return nil
                }
                array.append(converted)
            }
            return .array(array)
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(value.count)
            for (key, val) in value {
                guard let converted = JSONValue.from(any: val) else {
                    return nil
                }
                object[key] = converted
            }
            return .object(object)
        default:
            return nil
        }
    }
}
