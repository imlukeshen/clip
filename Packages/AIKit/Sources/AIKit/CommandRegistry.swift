import CoreModel
import Foundation

public struct CommandID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum CommandCategory: String, Codable, Sendable, CaseIterable {
    case asset, clip, effect, audio, timeline, image, pdf, file, view, app
}

public enum AgentExposure: String, Codable, Sendable {
    case always, onDemand, never
}

public struct CommandShortcut: Codable, Sendable, Equatable {
    public var key: String
    public var modifiers: [String]

    public init(_ key: String, modifiers: [String] = ["command"]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum Availability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// Metadata shared by menu, palette, and assistant renderings of a capability.
public protocol Command: Sendable {
    var id: CommandID { get }
    var title: String { get }
    var category: CommandCategory { get }
    var shortcut: CommandShortcut? { get }
    var isDestructive: Bool { get }
    var agentExposure: AgentExposure { get }
    var schema: ToolSchema { get }
}

public struct CommandDefinition: Command, Sendable, Equatable, Identifiable {
    public var id: CommandID
    public var title: String
    public var category: CommandCategory
    public var shortcut: CommandShortcut?
    public var isDestructive: Bool
    public var agentExposure: AgentExposure
    public var schema: ToolSchema

    public init(
        id: CommandID,
        title: String,
        category: CommandCategory,
        shortcut: CommandShortcut? = nil,
        isDestructive: Bool = false,
        agentExposure: AgentExposure,
        schema: ToolSchema
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.agentExposure = agentExposure
        self.schema = schema
    }
}

/// The single capability catalog for Clip's user and assistant surfaces.
public enum CommandRegistry {
    public static let all: [CommandDefinition] = [
        command(
            "app.commandPalette", "Command Palette", .app,
            shortcut: .init("k"), kind: .read, exposure: .never),
        command(
            "navigation.inbox", "Open Media Browser", .view, kind: .confirm, exposure: .onDemand),
        command(
            "navigation.video", "Open Video Editor", .view, kind: .confirm, exposure: .onDemand),
        command(
            "navigation.photo", "Open Photo Editor", .view, kind: .confirm, exposure: .onDemand),
        command("navigation.pdf", "Open PDF Workspace", .view, kind: .confirm, exposure: .onDemand),
        command(
            "navigation.text", "Open Text Workspace", .view, kind: .confirm, exposure: .onDemand),
        command(
            "navigation.convert", "Open Convert Queue", .view, kind: .confirm, exposure: .onDemand),
        command(
            "capture.history", "Capture History", .app,
            shortcut: .init("c", modifiers: ["command", "shift"]), kind: .read, exposure: .never),
        command(
            "capture.clearHistory", "Clear Capture History", .app, destructive: true,
            kind: .confirm, exposure: .onDemand),
        command("edit.undo", "Undo", .app, exposure: .onDemand),
        command("edit.redo", "Redo", .app, exposure: .onDemand),
        command("asset.selectAll", "Select All", .asset, shortcut: .init("a"), exposure: .onDemand),
        command(
            "asset.deselectAll", "Deselect All", .asset,
            shortcut: .init("a", modifiers: ["command", "shift"]), exposure: .onDemand),
        command(
            "asset.search", "Search Library", .asset,
            shortcut: .init("f"), kind: .confirm, exposure: .onDemand),
        command(
            "asset.delete", "Move to Trash", .asset, shortcut: .init("delete"),
            destructive: true, kind: .confirm, exposure: .onDemand,
            properties: ["assetIDs": array(string)]),
        command(
            "asset.quickLook", "Quick Look", .asset,
            shortcut: .init("space", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "asset.reveal", "Reveal in Finder", .asset,
            shortcut: .init("r"), kind: .confirm, exposure: .onDemand),
        command("describeTimeline", "Describe Timeline", .timeline, kind: .read, exposure: .always),
        command(
            "describeClip", "Describe Clip", .clip, kind: .read, exposure: .onDemand,
            required: ["itemID"], properties: ["itemID": string]),
        command(
            "trimClip", "Trim Clip", .clip, exposure: .always,
            required: ["itemID", "start", "end"],
            properties: ["itemID": string, "start": number, "end": number]),
        command(
            "splitClip", "Split Clip", .clip,
            shortcut: .init("k", modifiers: ["command", "shift"]), exposure: .always,
            required: ["itemID", "at"], properties: ["itemID": string, "at": number]),
        command(
            "reorderClips", "Reorder Clips", .timeline, exposure: .always,
            required: ["order"], properties: ["order": array(string)]),
        command(
            "timeline.toggleSnapping", "Toggle Snapping", .timeline,
            shortcut: .init("s", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.rippleDelete", "Ripple Delete", .timeline,
            shortcut: .init("delete", modifiers: ["shift"]), destructive: true,
            exposure: .onDemand, required: ["itemID"], properties: ["itemID": string]),
        command(
            "timeline.roll", "Roll Edit", .timeline, exposure: .onDemand,
            required: ["itemID", "delta"],
            properties: ["itemID": string, "delta": number]),
        command(
            "timeline.slip", "Slip Clip", .timeline, exposure: .onDemand,
            required: ["itemID", "delta"],
            properties: ["itemID": string, "delta": number]),
        command(
            "timeline.slide", "Slide Clip", .timeline, exposure: .onDemand,
            required: ["itemID", "delta"],
            properties: ["itemID": string, "delta": number]),
        command(
            "timeline.razorTool", "Razor Tool", .timeline,
            shortcut: .init("c", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.shuttleBackward", "Shuttle Backward", .timeline,
            shortcut: .init("j", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.shuttlePause", "Pause Shuttle", .timeline,
            shortcut: .init("k", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.shuttleForward", "Shuttle Forward", .timeline,
            shortcut: .init("l", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.setIn", "Set In Point", .timeline,
            shortcut: .init("i", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.setOut", "Set Out Point", .timeline,
            shortcut: .init("o", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.addMarker", "Add Marker", .timeline,
            shortcut: .init("m", modifiers: []), exposure: .onDemand,
            properties: ["time": number, "name": string]),
        command(
            "timeline.nextMarker", "Go to Next Marker", .timeline,
            shortcut: .init("m", modifiers: ["shift"]), kind: .confirm,
            exposure: .onDemand),
        command(
            "timeline.insert", "Insert Source", .timeline, kind: .confirm,
            exposure: .onDemand),
        command(
            "timeline.overwrite", "Overwrite from Source", .timeline, kind: .confirm,
            exposure: .onDemand),
        command(
            "timeline.pasteAttributes", "Paste Attributes", .timeline,
            shortcut: .init("v", modifiers: ["command", "option"]), kind: .confirm,
            exposure: .onDemand),
        command(
            "timeline.targetTrack", "Cycle Target Track", .timeline, kind: .confirm,
            exposure: .onDemand),
        command(
            "timeline.crossDissolve", "Apply Cross Dissolve", .timeline,
            shortcut: .init("d"), exposure: .onDemand,
            required: ["itemID", "duration"],
            properties: ["itemID": string, "duration": number]),
        command(
            "timeline.audioFade", "Set Audio Fade", .audio, exposure: .onDemand,
            required: ["itemID", "fadeIn", "fadeOut"],
            properties: ["itemID": string, "fadeIn": number, "fadeOut": number]),
        command(
            "timeline.setTrackState", "Set Track State", .timeline, exposure: .onDemand,
            required: ["trackID", "property", "value"],
            properties: ["trackID": string, "property": string, "value": boolean]),
        command(
            "setSpeed", "Set Speed", .clip, exposure: .always,
            required: ["itemID", "speed"], properties: ["itemID": string, "speed": number]),
        command(
            "setKeyframe", "Set Keyframe", .effect, exposure: .always,
            required: ["property", "time", "value"],
            properties: [
                "property": string, "time": number, "value": keyframeValue,
                "itemID": string, "trackID": string, "effectID": string,
                "easing": string,
            ]),
        command(
            "addZoom", "Add Zoom", .effect, exposure: .always,
            required: ["itemID", "range", "center", "scale"],
            properties: ["itemID": string, "range": range, "center": point, "scale": number]),
        command(
            "autoZoomFromClicks", "Auto Zoom from Clicks", .effect, exposure: .always,
            required: ["itemIDs"], properties: ["itemIDs": array(string), "options": object]),
        command(
            "removeEffect", "Remove Effect", .effect, destructive: true, exposure: .always,
            required: ["itemID", "effectID"],
            properties: ["itemID": string, "effectID": string]),
        command(
            "setBackground", "Set Background", .effect, exposure: .always,
            required: ["itemIDs", "padding", "radius", "style"],
            properties: [
                "itemIDs": array(string), "padding": number, "radius": number, "style": object,
            ]),
        command(
            "detectSilence", "Detect Silence", .audio, kind: .read, exposure: .onDemand,
            required: ["itemIDs", "thresholdDB"],
            properties: ["itemIDs": array(string), "thresholdDB": number]),
        command(
            "trimSilence", "Trim Silence", .audio, exposure: .always,
            required: ["itemIDs", "thresholdDB"],
            properties: ["itemIDs": array(string), "thresholdDB": number]),
        command(
            "generateCaptions", "Generate Captions", .audio, exposure: .always,
            required: ["itemIDs", "engine"],
            properties: ["itemIDs": array(string), "engine": string]),
        command(
            "exportProject", "Export Project", .file, kind: .confirm, exposure: .always,
            required: ["preset", "destination"],
            properties: ["preset": string, "destination": string]),
        command(
            "setPreference", "Set Preference", .app, kind: .confirm, exposure: .onDemand,
            required: ["key", "value"], properties: ["key": string, "value": object]),
        command("view.getSelection", "Get Selection", .view, kind: .read, exposure: .always),
        command("view.getPlayhead", "Get Playhead", .view, kind: .read, exposure: .always),
        command(
            "timeline.describe", "Describe Timeline Structure", .timeline, kind: .read,
            exposure: .onDemand),
        command("audio.describe", "Describe Audio", .audio, kind: .read, exposure: .onDemand),
        command(
            "view.getFrame", "Get Frame", .view, kind: .confirm, exposure: .onDemand,
            required: ["at"], properties: ["at": number]),
        command(
            "cropTo", "Crop Image", .image, exposure: .onDemand,
            properties: ["aspect": string, "rect": rect]),
        command(
            "addAnnotation", "Add Image Annotation", .image, exposure: .onDemand,
            required: ["type", "rect"],
            properties: ["type": string, "rect": rect, "text": string]),
        command(
            "suggestRedactions", "Suggest Image Redactions", .image,
            kind: .read, exposure: .onDemand),
        command(
            "applyRedactions", "Apply Suggested Redactions", .image, exposure: .onDemand,
            required: ["suggestionIDs"], properties: ["suggestionIDs": array(string)]),
        command(
            "addPadding", "Add Image Padding", .image, exposure: .onDemand,
            properties: ["amount": number, "color": object]),
        command(
            "generateAltText", "Generate Image Alt Text", .image,
            kind: .read, exposure: .onDemand),
        command(
            "numberSteps", "Number Image Steps", .image, exposure: .onDemand),
        command(
            "pdf.describe", "Describe PDF", .pdf, kind: .read, exposure: .onDemand),
        command(
            "pdf.addText", "Add PDF Text", .pdf, exposure: .onDemand,
            required: ["text", "rect"],
            properties: [
                "pageID": string, "text": string, "rect": rect, "fontSize": number,
            ]),
        command(
            "pdf.highlight", "Highlight PDF Region", .pdf, exposure: .onDemand,
            required: ["rect"], properties: ["pageID": string, "rect": rect]),
        command(
            "pdf.redact", "Redact PDF Region", .pdf, destructive: true, exposure: .onDemand,
            required: ["rect"], properties: ["pageID": string, "rect": rect]),
        command(
            "pdf.rotatePage", "Rotate PDF Page", .pdf, exposure: .onDemand,
            properties: ["pageID": string]),
        command(
            "pdf.reorderPage", "Reorder PDF Page", .pdf, exposure: .onDemand,
            required: ["destination"],
            properties: ["pageID": string, "destination": number]),
        command(
            "pdf.ocrPage", "Recognize PDF Page Text", .pdf, exposure: .onDemand,
            properties: ["pageID": string]),
        command(
            "pdf.toMarkdown", "Convert PDF to Markdown", .pdf,
            kind: .read, exposure: .onDemand),
        command(
            "listCommands", "List Commands", .app, kind: .read, exposure: .always,
            properties: ["category": string, "query": string]),
        command(
            "runCommand", "Run Command", .app, exposure: .always,
            required: ["id"], properties: ["id": string, "arguments": object]),
    ]

    /// Deliberately non-agent commands require a documented entry here.
    public static let explicitlyExcluded: [CommandID: String] = [
        "app.commandPalette": "Opening UI chrome has no useful assistant-side effect.",
        "capture.history": "Opening UI chrome has no useful assistant-side effect.",
    ]

    public static func command(id: CommandID) -> CommandDefinition? {
        all.first { $0.id == id }
    }

    public static func command(named name: String) -> CommandDefinition? {
        command(id: CommandID(rawValue: name))
    }

    public static func commands(
        category: CommandCategory? = nil,
        query: String? = nil
    ) -> [CommandDefinition] {
        all.filter { command in
            let matchesQuery =
                query.map { value in
                    value.isEmpty
                        || command.title.localizedCaseInsensitiveContains(value)
                        || command.id.rawValue.localizedCaseInsensitiveContains(value)
                } ?? true
            return command.agentExposure != .never
                && (category == nil || command.category == category)
                && matchesQuery
        }
    }

    private static let string: JSONValue = .object(["type": .string("string")])
    private static let number: JSONValue = .object(["type": .string("number")])
    private static let boolean: JSONValue = .object(["type": .string("boolean")])
    private static let object: JSONValue = .object(["type": .string("object")])
    private static let point: JSONValue = typedObject(
        ["x": number, "y": number], required: ["x", "y"])
    private static let range: JSONValue = typedObject(
        ["start": number, "end": number], required: ["start", "end"])
    private static let rect: JSONValue = typedObject(
        ["x": number, "y": number, "width": number, "height": number],
        required: ["x", "y", "width", "height"])
    private static let keyframeValue: JSONValue = .object([
        "anyOf": .array([number, object])
    ])

    private static func array(_ item: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": item])
    }

    private static func typedObject(
        _ properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func command(
        _ id: CommandID,
        _ title: String,
        _ category: CommandCategory,
        shortcut: CommandShortcut? = nil,
        destructive: Bool = false,
        kind: ToolKind = .write,
        exposure: AgentExposure,
        required: [String] = [],
        properties: [String: JSONValue] = [:]
    ) -> CommandDefinition {
        CommandDefinition(
            id: id,
            title: title,
            category: category,
            shortcut: shortcut,
            isDestructive: destructive,
            agentExposure: exposure,
            schema: ToolSchema(
                name: id.rawValue,
                description: title,
                kind: kind,
                parameters: typedObject(properties, required: required)
            )
        )
    }
}

/// Compatibility facade for provider adapters.
public enum ToolCatalog {
    public static var all: [ToolSchema] {
        CommandRegistry.all.compactMap { command in
            command.agentExposure == .always ? command.schema : nil
        }
    }

    public static func schema(named name: String) -> ToolSchema? {
        CommandRegistry.command(named: name)?.schema
    }
}

extension ToolSchema {
    public var hasValidObjectSchema: Bool {
        guard case .object(let root) = parameters,
            root["type"] == .string("object"),
            case .object(let properties) = root["properties"],
            case .array(let required) = root["required"]
        else { return false }
        return required.allSatisfy { value in
            guard case .string(let name) = value else { return false }
            return properties[name] != nil
        }
    }
}
