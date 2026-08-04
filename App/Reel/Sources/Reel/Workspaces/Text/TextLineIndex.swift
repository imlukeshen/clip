import Foundation

struct TextLineIndex: Sendable {
    private(set) var starts = [0]
    private(set) var length = 0

    static func make(for text: String) -> TextLineIndex? {
        var result = TextLineIndex()
        result.starts.reserveCapacity(max(text.utf8.count / 40, 1))
        let utf16 = text.utf16
        var index = utf16.startIndex
        var offset = 0
        while index < utf16.endIndex {
            if offset.isMultiple(of: 4_096), Task<Never, Never>.isCancelled {
                return nil
            }
            let scalar = utf16[index]
            index = utf16.index(after: index)
            offset += 1
            if scalar == 0x0D, index < utf16.endIndex, utf16[index] == 0x0A {
                index = utf16.index(after: index)
                offset += 1
                result.starts.append(offset)
            } else if scalar == 0x0D || scalar == 0x0A {
                result.starts.append(offset)
            }
        }
        result.length = offset
        return result
    }

    func position(at requestedLocation: Int) -> (line: Int, column: Int) {
        let location = min(max(requestedLocation, 0), length)
        let index = lineIndex(at: location)
        return (index + 1, location - starts[index] + 1)
    }

    func lineNumber(at requestedLocation: Int) -> Int {
        lineIndex(at: min(max(requestedLocation, 0), length)) + 1
    }

    func location(ofLine requestedLine: Int) -> Int {
        starts[min(max(requestedLine - 1, 0), starts.count - 1)]
    }

    func range(ofLine requestedLine: Int) -> NSRange {
        let index = min(max(requestedLine - 1, 0), starts.count - 1)
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] : length
        return NSRange(location: start, length: end - start)
    }

    var lineCount: Int { starts.count }

    private func lineIndex(at location: Int) -> Int {
        var lowerBound = 0
        var upperBound = starts.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if starts[midpoint] <= location {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(lowerBound - 1, 0)
    }
}
