//
//  AnyCoder.swift
//  SQLiteORM
//
//  Created by Valo on 2020/7/30.
//

import Foundation

open class AnyEncoder {
    struct Options: OptionSet {
        let rawValue: Int
        static let includeEmptyFields = Options(rawValue: 1 << 0)
    }

    open class func encode<T>(_ any: T) throws -> [String: Binding] {
        guard let temp = reflect(any) as? [String: Any] else {
            throw EncodingError.invalidEncode(any)
        }
        var encoded: [String: Binding] = [:]
        for (key, value) in temp {
            switch value {
                case let value as Binding:
                    encoded[key] = value
                case _ as NSNull:
                    break
                default:
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    let string = String(bytes: data.bytes)
                    encoded[key] = string
            }
        }
        return encoded
    }

    open class func encode<T>(_ values: [T]) -> [[String: Binding]] {
        var array = [[String: Binding]]()
        for value in values {
            do {
                let encoded = try encode(value)
                array.append(encoded)
            } catch _ {
                array.append([:])
            }
        }
        return array
    }

    class func reflect<T>(_ any: T, options: Options = []) -> Any? {
        return reflect(element: any, options: options)
    }

    // MARK: - Private

    private class func reflect<T>(element: T, options: Options = []) -> Any? {
        guard let result = value(for: element, options: options, depth: 0) else {
            return nil
        }
        switch result {
            case _ as [Any], _ as [String: Any]:
                return result
            default:
                return [result]
        }
    }

    private class func value(for any: Any, options: Options = [], depth: Int) -> Any? {
        if let binding = any as? Binding {
            if depth > 1, let data = binding as? Data {
                return data.hex
            }
            return binding
        }

        let mirror = Mirror(reflecting: any)
        if mirror.children.isEmpty {
            switch any {
                case _ as Binding:
                    return any
                case _ as Optional<Any>:
                    if let displayStyle = mirror.displayStyle {
                        switch displayStyle {
                            case .enum:
                                return value(forEnum: any)
                            default:
                                break
                        }
                    }
                    if options.contains(.includeEmptyFields) {
                        fallthrough
                    } else {
                        return nil
                    }
                default:
                    return String(describing: any)
            }
        } else if let displayStyle = mirror.displayStyle {
            switch displayStyle {
                case .class, .dictionary, .struct:
                    return dictionary(from: mirror, options: options, depth: depth)
                case .collection, .set, .tuple:
                    return array(from: mirror, options: options, depth: depth)
                case .enum, .optional:
                    return value(for: mirror.children.first!.value, options: options, depth: depth)
                @unknown default:
                    print("not matched")
                    return nil
            }
        } else {
            return nil
        }
    }

    private class func dictionary(from mirror: Mirror, options: Options = [], depth: Int) -> [String: Any] {
        return mirror.children.reduce(into: [String: Any]()) {
            var key: String!
            var value: Any!
            if let label = $1.label {
                key = label
                value = $1.value
            } else {
                let array = self.array(from: Mirror(reflecting: $1.value), options: options, depth: depth + 1)
                guard 2 <= array.count,
                    let newKey = (array[0] as? String) else {
                    return
                }
                key = newKey
                value = array[1]
            }
            if let value = self.value(for: value!, options: options, depth: depth + 1) {
                $0[key] = value
            }
        }
    }

    private class func array(from mirror: Mirror, options: Options = [], depth: Int) -> [Any] {
        return mirror.children.compactMap {
            value(for: $0.value, options: options, depth: depth)
        }
    }

    private class func value(forEnum item: Any) -> UInt8 {
        let result = withUnsafeBytes(of: item) { [UInt8]($0).first ?? 0 }
        return result
    }
}

open class AnyDecoder {
    open class func decode<T>(_ type: T.Type, from containers: [[String: Binding]]) throws -> [T] {
        return try containers.map { try decode(type, from: $0) }
    }

    open class func decode<T>(_ type: T.Type, from container: [String: Binding]) throws -> T {
        guard let result = try createObject(type, from: container) as? T else {
            throw DecodingError.mismatch(type)
        }
        return result
    }

    private class func createObject(_ type: Any.Type, from container: [String: Any]) throws -> Any {
        var info = try typeInfo(of: type)
        let genericType: Any.Type
        if info.kind == .optional {
            guard info.genericTypes.count == 1 else {
                throw DecodingError.mismatch(type)
            }
            genericType = info.genericTypes.first!
            info = try typeInfo(of: genericType)
        } else {
            genericType = type
        }
        var object = try createInstance(of: genericType)
        for prop in info.properties {
            if prop.name.count == 0 { continue }
            if let value = container[prop.name] {
                if let string = value as? String {
                    switch prop.type {
                        case is String?.Type: fallthrough
                        case is String.Type:
                            try prop.set(value: string, on: &object)

                        case is Data?.Type: fallthrough
                        case is Data.Type:
                            let data = Data(hex: string)
                            try prop.set(value: data, on: &object)

                        default:
                            let data = Data(string.bytes)
                            let json = try? JSONSerialization.jsonObject(with: data, options: [])
                            switch json {
                                case let array as [[String: Any]]:
                                    var subs: [Any] = []
                                    for dictionary in array {
                                        if let sub = try? createObject(prop.type, from: dictionary) {
                                            subs.append(sub)
                                        }
                                    }
                                    try prop.set(value: subs, on: &object)

                                case let array as [Any]:
                                    try prop.set(value: array, on: &object)

                                case let dictionary as [String: Any]:
                                    let sub = try createObject(prop.type, from: dictionary)
                                    try prop.set(value: sub, on: &object)

                                default:
                                    break
                            }
                    }
                } else {
                    var val = value
                    let xinfo = try typeInfo(of: prop.type)
                    if xinfo.kind == .enum, let xval = value as? UInt8 {
                        let pval = UnsafeMutableRawPointer.allocate(byteCount: xinfo.size, alignment: xinfo.alignment)
                        pval.storeBytes(of: xval, as: UInt8.self)
                        defer { pval.deallocate() }
                        try setProperties(typeInfo: xinfo, pointer: pval)
                        val = getters(type: prop.type).get(from: pval)
                    } else if let xval = value as? Binding {
                        switch prop.type {
                            case is Int.Type: val = Int(binding: xval) ?? 0
                            case is Int8.Type: val = Int8(binding: xval) ?? 0
                            case is Int16.Type: val = Int16(binding: xval) ?? 0
                            case is Int32.Type: val = Int32(binding: xval) ?? 0
                            case is Int64.Type: val = Int64(binding: xval) ?? 0
                            case is UInt.Type: val = UInt(binding: xval) ?? 0
                            case is UInt8.Type: val = UInt8(binding: xval) ?? 0
                            case is UInt16.Type: val = UInt16(binding: xval) ?? 0
                            case is UInt32.Type: val = UInt32(binding: xval) ?? 0
                            case is UInt64.Type: val = UInt64(binding: xval) ?? 0
                            case is Bool.Type: val = Bool(binding: xval) ?? 0
                            case is Float.Type: val = Float(binding: xval) ?? 0.0
                            case is Double.Type: val = Double(binding: xval) ?? 0.0
                            case is Data.Type: val = Data(binding: xval) ?? Data()
                            case is String.Type: val = String(binding: xval) ?? ""
                            default: break
                        }
                    }
                    try prop.set(value: val, on: &object)
                }
            }
        }

        return object
    }
}
