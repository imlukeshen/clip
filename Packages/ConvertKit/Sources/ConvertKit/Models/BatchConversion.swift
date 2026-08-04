import Foundation

public struct BatchConversionJob: Identifiable, Sendable {
    public var id: UUID
    public var plan: ConversionPlan
    public var input: URL
    public var output: URL

    public init(
        id: UUID = UUID(),
        plan: ConversionPlan,
        input: URL,
        output: URL
    ) {
        self.id = id
        self.plan = plan
        self.input = input
        self.output = output
    }
}

public enum BatchItemOutcome: Sendable, Equatable {
    case succeeded(URL)
    case failed(String)
    case cancelled
}

public struct BatchProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var itemIndex: Int
    public var itemID: UUID?
    public var itemProgress: Double
    public var aggregateProgress: Double
    public var outcome: BatchItemOutcome?

    public init(
        completed: Int,
        total: Int,
        itemIndex: Int,
        itemID: UUID? = nil,
        itemProgress: Double,
        aggregateProgress: Double? = nil,
        outcome: BatchItemOutcome? = nil
    ) {
        self.completed = completed
        self.total = total
        self.itemIndex = itemIndex
        self.itemID = itemID
        self.itemProgress = itemProgress
        self.aggregateProgress = aggregateProgress ?? Double(completed) / Double(max(total, 1))
        self.outcome = outcome
    }
}
