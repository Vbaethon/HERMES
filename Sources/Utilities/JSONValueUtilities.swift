import Foundation

enum JSONValueUtilities {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = string(value), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return Int(string(value) ?? "") ?? 0
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        let text = (string(value) ?? "").lowercased()
        return text == "true" || text == "1" || text == "yes"
    }

    static func mutableDictionary(_ value: Any?) -> NSMutableDictionary {
        if let dictionary = value as? NSDictionary {
            return dictionary.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        }
        return NSMutableDictionary()
    }
}
