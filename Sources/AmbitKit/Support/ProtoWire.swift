import Foundation

/// Minimal protobuf wire-format reader and writer: just enough to read the handful of fields
/// Ambit uses from device APIs, without a protobuf dependency or generated code.
enum ProtoValue: Equatable {
    case varint(UInt64)
    case fixed64(UInt64)
    case bytes(Data)
    case fixed32(UInt32)
}

struct ProtoField: Equatable {
    var number: Int
    var value: ProtoValue

    var uint: UInt64? { if case .varint(let v) = value { v } else { nil } }
    var bool: Bool? { uint.map { $0 != 0 } }
    var float: Double? { if case .fixed32(let v) = value { Double(Float(bitPattern: v)) } else { nil } }
    var data: Data? { if case .bytes(let v) = value { v } else { nil } }
    var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}

struct ProtoError: Error, Equatable {}

enum ProtoWire {
    /// Decodes one message into its top-level fields, in wire order. Throws on truncated or
    /// malformed input rather than returning partial data.
    static func fields(_ data: Data) throws -> [ProtoField] {
        var bytes = [UInt8](data)[...]
        var fields: [ProtoField] = []
        while !bytes.isEmpty {
            let key = try varint(&bytes)
            let number = Int(key >> 3)
            guard number > 0 else { throw ProtoError() }
            switch key & 7 {
            case 0:
                fields.append(ProtoField(number: number, value: .varint(try varint(&bytes))))
            case 1:
                fields.append(ProtoField(number: number, value: .fixed64(try fixed(&bytes, count: 8))))
            case 2:
                let length = try varint(&bytes)
                guard length <= UInt64(bytes.count) else { throw ProtoError() }
                fields.append(ProtoField(number: number, value: .bytes(Data(bytes.prefix(Int(length))))))
                bytes = bytes.dropFirst(Int(length))
            case 5:
                fields.append(ProtoField(number: number, value: .fixed32(UInt32(try fixed(&bytes, count: 4)))))
            default:
                throw ProtoError()
            }
        }
        return fields
    }

    private static func varint(_ bytes: inout ArraySlice<UInt8>) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = bytes.popFirst() {
            guard shift < 64 else { throw ProtoError() }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoError()
    }

    private static func fixed(_ bytes: inout ArraySlice<UInt8>, count: Int) throws -> UInt64 {
        guard bytes.count >= count else { throw ProtoError() }
        var result: UInt64 = 0
        for (index, byte) in bytes.prefix(count).enumerated() { result |= UInt64(byte) << UInt64(8 * index) }
        bytes = bytes.dropFirst(count)
        return result
    }

    static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    static func message(field number: Int, _ body: Data) -> Data {
        encodeVarint(UInt64(number) << 3 | 2) + encodeVarint(UInt64(body.count)) + body
    }

    static func bool(field number: Int, _ value: Bool) -> Data {
        encodeVarint(UInt64(number) << 3) + encodeVarint(value ? 1 : 0)
    }
}
