import AIKit
import ConvertKit
import CoreModel
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@Suite("V4 conversion agent")
struct V4ConversionAgentTests {
    @Test("Conversion commands expose the required confirmation contract")
    func commandContract() throws {
        #expect(CommandRegistry.command(named: "convert.listTargets")?.schema.kind == .read)
        #expect(CommandRegistry.command(named: "convert.plan")?.schema.kind == .read)
        #expect(CommandRegistry.command(named: "convert.presets")?.schema.kind == .read)
        #expect(CommandRegistry.command(named: "convert.run")?.schema.kind == .confirm)
        #expect(ToolCatalog.schema(named: "convert.run") != nil)
    }

    @Test("Four screenshots are planned, confirmed, and executed below a hard size ceiling")
    func screenshotAcceptance() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-v4-agent-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let records = (1...4).map(Self.screenshot)
        let assets = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "agent-convert"),
            name: "Agent Convert",
            timeline: Timeline(),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let recorder = ConversionRecorder()
        let context = ToolExecutionContext(
            document: document,
            assets: assets,
            eventTracks: [:],
            resolving: { id in folder.appendingPathComponent("\(id.rawValue).png") },
            conversionDestination: folder,
            converting: { jobs in await recorder.run(jobs) }
        )
        let arguments: [String: JSONValue] = [
            "assetIDs": .array(records.map { .string($0.id.rawValue) }),
            "target": .string("jpeg"),
            "quality": .number(72),
            "maximumBytes": .number(500 * 1_024),
            "longestSide": .number(1_600),
            "stripMetadata": .bool(true),
            "filenameTemplate": .string("{name}-web"),
        ]
        let executor = ToolExecutor()

        let plan = try await executor.execute(
            invocation("convert.plan", arguments),
            turnID: "plan",
            policy: .autoApply,
            context: context
        )
        #expect(plan.message.contains("Conversion plan for 4 assets"))
        #expect(plan.message.contains("lossy"))
        #expect(plan.message.contains("hard maximum 512000 bytes"))

        let pending = try await executor.execute(
            invocation("convert.run", arguments, id: "conversion-write"),
            turnID: "run",
            policy: .autoApply,
            context: context
        )
        #expect(pending.requiresConfirmation)
        #expect(pending.message.contains("Confirm writing 4 converted files"))
        #expect(await recorder.jobs().isEmpty)

        let result = try await executor.execute(
            invocation("convert.run", arguments, id: "conversion-write"),
            turnID: "run",
            policy: .autoApply,
            context: context,
            confirmed: true
        )
        #expect(!result.requiresConfirmation)
        #expect(result.message.contains("Converted 4 of 4 files"))
        let jobs = await recorder.jobs()
        #expect(jobs.count == 4)
        #expect(jobs.allSatisfy { $0.output.pathExtension == "jpg" })
        #expect(
            jobs.allSatisfy {
                $0.plan.steps.first?.options.image?.maximumFileSize == 500 * 1_024
            }
        )
        #expect(jobs.allSatisfy { $0.plan.steps.first?.options.removesMetadata == true })

        let presets = try await executor.execute(
            invocation("convert.presets", [:]),
            turnID: "presets",
            policy: .autoApply,
            context: context
        )
        #expect(presets.message.contains("web-ready-mp4"))
        #expect(presets.message.contains("slack-gif"))
    }

    private static func screenshot(_ index: Int) -> AssetRecord {
        let id = AssetID(rawValue: "screenshot-\(index)")
        return AssetRecord(
            id: id,
            relativePath: "Media/Screenshot \(index).png",
            displayName: "Screenshot \(index).png",
            kind: .image,
            container: "png",
            createdAt: Date(timeIntervalSince1970: Double(index)),
            importedAt: Date(timeIntervalSince1970: Double(index)),
            byteSize: 2_000_000,
            contentHash: id.rawValue,
            width: 2_560,
            height: 1_440,
            ingestState: .ready
        )
    }
}

private actor ConversionRecorder {
    private var captured: [BatchConversionJob] = []

    func run(_ jobs: [BatchConversionJob]) -> [BatchItemOutcome] {
        captured = jobs
        return jobs.map { .succeeded($0.output) }
    }

    func jobs() -> [BatchConversionJob] { captured }
}

private func invocation(
    _ name: String,
    _ arguments: [String: JSONValue],
    id: String = UUID().uuidString
) -> ToolInvocation {
    ToolInvocation(callID: id, name: name, arguments: .object(arguments))
}
