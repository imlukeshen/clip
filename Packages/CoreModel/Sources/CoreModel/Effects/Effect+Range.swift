import Foundation

extension Effect {
    func replacingRange(_ range: TimeRange) -> Effect {
        switch self {
        case .zoom(var value):
            value.range = range
            return .zoom(value)
        case .crop(var value):
            value.range = range
            return .crop(value)
        case .background(var value):
            value.range = range
            return .background(value)
        case .blur(var value):
            value.range = range
            return .blur(value)
        case .cursor(var value):
            value.range = range
            return .cursor(value)
        case .text(var value):
            value.range = range
            return .text(value)
        case .unknown(var value):
            value.range = range
            if case .object(var object) = value.rawValue {
                object["range"] = range.jsonValue
                value.rawValue = .object(object)
            }
            return .unknown(value)
        }
    }
}

extension TimeRange {
    fileprivate var jsonValue: JSONValue {
        .object([
            "duration": duration.jsonValue,
            "start": start.jsonValue,
        ])
    }
}

extension RationalTime {
    fileprivate var jsonValue: JSONValue {
        .object([
            "timescale": .number(Double(timescale)),
            "value": .number(Double(value)),
        ])
    }
}
