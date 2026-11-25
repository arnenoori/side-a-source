import Foundation

/// A QR code in byte mode, for the pairing link in a terminal. The phone's Camera reads the same link from the Mac's
/// pairing sheet, so this has to produce a standard code: levels L and M, versions 1 to 40, every mask tried. The structure
/// follows the ISO/IEC 18004 algorithm as Project Nayuki publishes it; a test decodes our output with CoreImage for every
/// version a link can need.
public struct QRCode: Sendable {
    public enum Level: Int, Sendable { case low = 0, medium = 1 }

    public let version: Int
    public let size: Int
    public let level: Level
    public let mask: Int
    private var modules: [[Bool]]

    public func dark(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < size && y >= 0 && y < size && modules[y][x] }

    public enum Failure: Error { case tooLong }

    public init(text: String, level: Level = .medium) throws {
        let data = Array(text.utf8)
        var found: Int?
        for candidate in 1...40 {
            let capacity = Self.dataCodewords(candidate, level) * 8
            let bits = 4 + (candidate < 10 ? 8 : 16) + data.count * 8
            if bits <= capacity { found = candidate; break }
        }
        guard let version = found else { throw Failure.tooLong }
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) { for shift in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> shift) & 1 == 1) } }
        append(0b0100, 4)
        append(data.count, version < 10 ? 8 : 16)
        for byte in data { append(Int(byte), 8) }
        let capacity = Self.dataCodewords(version, level) * 8
        append(0, min(4, capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacity { append(pad, 8); pad = pad == 0xEC ? 0x11 : 0xEC }
        var codewords: [UInt8] = stride(from: 0, to: bits.count, by: 8).map { start in
            UInt8(bits[start..<start + 8].reduce(0) { $0 << 1 | ($1 ? 1 : 0) })
        }
        codewords = Self.interleave(codewords, version, level)

        self.version = version
        self.level = level
        size = version * 4 + 17
        var grid = Grid(size: size, version: version)
        grid.drawFunctionPatterns(level: level, mask: 0)
        grid.draw(codewords: codewords)
        var best = 0, bestPenalty = Int.max
        for candidate in 0..<8 {
            grid.apply(mask: candidate)
            grid.drawFormat(level: level, mask: candidate)
            let penalty = grid.penalty()
            if penalty < bestPenalty { best = candidate; bestPenalty = penalty }
            grid.apply(mask: candidate)
        }
        grid.apply(mask: best)
        grid.drawFormat(level: level, mask: best)
        mask = best
        modules = grid.modules
    }

    /// Two module rows per text line with half blocks, black on white whatever the terminal's colours, in a quiet zone of
    /// `border` modules.
    public func terminal(border: Int = 3) -> String {
        var out = ""
        let paint = "\u{1B}[30;107m", reset = "\u{1B}[0m"
        for y in stride(from: -border, to: size + border, by: 2) {
            out += paint
            for x in -border..<size + border {
                switch (dark(x, y), dark(x, y + 1)) {
                case (false, false): out += " "
                case (true, false): out += "▀"
                case (false, true): out += "▄"
                case (true, true): out += "█"
                }
            }
            out += reset + "\n"
        }
        return out
    }

    // MARK: Capacity and error correction

    private static let eccPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    ]
    private static let blocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    ]

    static func rawModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = version / 7 + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    static func dataCodewords(_ version: Int, _ level: Level) -> Int {
        rawModules(version) / 8 - eccPerBlock[level.rawValue][version] * blocks[level.rawValue][version]
    }

    private static func interleave(_ data: [UInt8], _ version: Int, _ level: Level) -> [UInt8] {
        let blockCount = blocks[level.rawValue][version], eccLength = eccPerBlock[level.rawValue][version]
        let raw = rawModules(version) / 8
        let shortBlocks = blockCount - raw % blockCount
        let shortLength = raw / blockCount
        var split: [[UInt8]] = []
        let divisor = reedSolomonDivisor(eccLength)
        var offset = 0
        for index in 0..<blockCount {
            let length = shortLength - eccLength + (index < shortBlocks ? 0 : 1)
            var block = Array(data[offset..<offset + length])
            offset += length
            let ecc = reedSolomonRemainder(block, divisor)
            if index < shortBlocks { block.append(0) }
            split.append(block + ecc)
        }
        var out: [UInt8] = []
        for column in 0..<split[0].count {
            for (index, block) in split.enumerated() where column != shortLength - eccLength || index >= shortBlocks { out.append(block[column]) }
        }
        return out
    }

    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for shift in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> shift) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }

    private static func reedSolomonDivisor(_ degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for index in 0..<degree {
                result[index] = multiply(result[index], root)
                if index + 1 < degree { result[index] ^= result[index + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    private static func reedSolomonRemainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for index in 0..<divisor.count { result[index] ^= multiply(divisor[index], factor) }
        }
        return result
    }

    // MARK: The grid

    private struct Grid {
        let size: Int
        let version: Int
        var modules: [[Bool]]
        var isFunction: [[Bool]]

        init(size: Int, version: Int) {
            self.size = size; self.version = version
            modules = Array(repeating: Array(repeating: false, count: size), count: size)
            isFunction = modules
        }

        mutating func set(_ x: Int, _ y: Int, _ dark: Bool) { modules[y][x] = dark; isFunction[y][x] = true }

        mutating func drawFunctionPatterns(level: Level, mask: Int) {
            for index in 0..<size { set(6, index, index % 2 == 0); set(index, 6, index % 2 == 0) }
            drawFinder(3, 3); drawFinder(size - 4, 3); drawFinder(3, size - 4)
            let positions = alignmentPositions()
            for (row, y) in positions.enumerated() {
                for (column, x) in positions.enumerated() {
                    let corner = (row == 0 && column == 0) || (row == 0 && column == positions.count - 1) || (row == positions.count - 1 && column == 0)
                    if !corner { drawAlignment(x, y) }
                }
            }
            drawFormat(level: level, mask: mask)
            drawVersion()
        }

        mutating func drawFinder(_ cx: Int, _ cy: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let distance = max(abs(dx), abs(dy)), x = cx + dx, y = cy + dy
                    if x >= 0 && x < size && y >= 0 && y < size { set(x, y, distance != 2 && distance != 4) }
                }
            }
        }

        mutating func drawAlignment(_ cx: Int, _ cy: Int) {
            for dy in -2...2 { for dx in -2...2 { set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) } }
        }

        func alignmentPositions() -> [Int] {
            guard version > 1 else { return [] }
            let count = version / 7 + 2
            // The patterns sit an even distance apart, the last pair at the far corner; version 32 is the standard's one exception.
            let step = version == 32 ? 26 : ((version * 4 + 4) + (count - 1) * 2 - 1) / ((count - 1) * 2) * 2
            var result = [6]
            var position = size - 7
            var tail: [Int] = []
            for _ in 0..<count - 1 { tail.insert(position, at: 0); position -= step }
            result += tail
            return result
        }

        mutating func drawFormat(level: Level, mask: Int) {
            let data = (level == .low ? 1 : 0) << 3 | mask
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = (data << 10 | remainder) ^ 0x5412
            func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }
            for index in 0...5 { set(8, index, bit(index)) }
            set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8))
            for index in 9..<15 { set(14 - index, 8, bit(index)) }
            for index in 0..<8 { set(size - 1 - index, 8, bit(index)) }
            for index in 8..<15 { set(8, size - 15 + index, bit(index)) }
            set(8, size - 8, true)
        }

        mutating func drawVersion() {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for index in 0..<18 {
                let value = (bits >> index) & 1 == 1
                let a = size - 11 + index % 3, b = index / 3
                set(a, b, value); set(b, a, value)
            }
        }

        mutating func draw(codewords: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for column in 0..<2 {
                        let x = right - column
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        if !isFunction[y][x] && index < codewords.count * 8 {
                            modules[y][x] = (codewords[index >> 3] >> (7 - (index & 7))) & 1 == 1
                            index += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func apply(mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y][x] {
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[y][x].toggle() }
                }
            }
        }

        func penalty() -> Int {
            var result = 0
            func runs(_ line: [Bool]) -> Int {
                var score = 0, run = 1
                for index in 1..<line.count {
                    if line[index] == line[index - 1] { run += 1 } else { if run >= 5 { score += run - 2 }; run = 1 }
                }
                if run >= 5 { score += run - 2 }
                return score
            }
            func finderLike(_ line: [Bool]) -> Int {
                let a: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
                let b = Array(a.reversed())
                var score = 0
                if line.count >= 11 {
                    for start in 0...(line.count - 11) {
                        let window = Array(line[start..<start + 11])
                        if window == a || window == b { score += 40 }
                    }
                }
                return score
            }
            for y in 0..<size { result += runs(modules[y]) + finderLike(modules[y]) }
            for x in 0..<size {
                let column = (0..<size).map { modules[$0][x] }
                result += runs(column) + finderLike(column)
            }
            for y in 0..<size - 1 {
                for x in 0..<size - 1 {
                    let color = modules[y][x]
                    if color == modules[y][x + 1] && color == modules[y + 1][x] && color == modules[y + 1][x + 1] { result += 3 }
                }
            }
            let dark = modules.reduce(0) { $0 + $1.filter { $0 }.count }
            let total = size * size
            let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
            result += max(0, k) * 10
            return result
        }
    }
}
