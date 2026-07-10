import Foundation

struct RussianSpellingBloom: Sendable {
    private static let headerSize = 20
    private static let fnvOffset: UInt64 = 0xcbf29ce484222325
    private static let fnvPrime: UInt64 = 0x100000001b3

    let wordCount: Int
    private let hashCount: Int
    private let bitCount: Int
    private let data: Data

    init(data: Data) throws {
        guard data.count >= Self.headerSize,
              String(data: data.prefix(4), encoding: .ascii) == "RSBF",
              Self.readUInt16(data, at: 4) == 1 else {
            throw LanguageModelError.invalidSection(13)
        }
        hashCount = Int(Self.readUInt16(data, at: 6))
        bitCount = Int(Self.readUInt32(data, at: 8))
        wordCount = Int(Self.readUInt64(data, at: 12))
        guard hashCount > 0,
              bitCount > 0,
              bitCount.nonzeroBitCount == 1,
              data.count == Self.headerSize + bitCount / 8 else {
            throw LanguageModelError.invalidSection(13)
        }
        self.data = data
    }

    func contains(_ word: String) -> Bool {
        let bytes = Array(word.utf8)
        guard !bytes.isEmpty else { return false }
        let first = Self.fnv1a64(bytes)
        let second = Self.fnv1a64(bytes.reversed()) | 1
        let mask = UInt64(bitCount - 1)
        for index in 0..<hashCount {
            let bit = (first &+ UInt64(index) &* second) & mask
            let byte = data[Self.headerSize + Int(bit >> 3)]
            guard byte & (1 << UInt8(bit & 7)) != 0 else { return false }
        }
        return true
    }

    private static func fnv1a64<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        bytes.reduce(fnvOffset) { ($0 ^ UInt64($1)) &* fnvPrime }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) }
    }
}
