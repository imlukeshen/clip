import CoreModel
import Foundation

public struct CommandID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum CommandCategory: String, Codable, Sendable, CaseIterable {
    case asset, clip, effect, audio, timeline, file, view, app
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

/// The single capability catalog for Reel's user and assistant surfaces.
public enum CommandRegistry {
    public static let all: [CommandDefinition] = [
        command(
            "app.commandPalette", "Command Palette", .app,
            shortcut: .init("k"), kind: .read, exposure: .never),
        command("navigation.inbox", "Open Media Browser", .view, kind: .confirm, exposure: .onDemand),
        command("navigation.video", "Open Video Editor", .view, kind: .confirm, exposure: .onDemand),
        command("navigation.photo", "Open Photo Editor", .view, kind: .confirm, exposure: .onDemand),
        command("navigation.pdf", "Open PDF Workspace", .view, kind: .confirm, exposure: .onDemand),
        command("navigation.convert", "Open Convert Queue", .view, kind: .confirm, exposure: .onDemand),
        command("edit.undo", "Undo", .app, exposure: .onDemand),
        command("edit.redo", "Redo", .app, exposure: .onDemand),
        command("asset.selectAll", "Select All", .asset, shortcut: .init("a"), exposure: .onDemand),
        command(
            "asset.deselectAll", "Deselect All", .asset,
            shortcut: .init("a", modifiers: ["command", "shift"]), exposure: .onDemand),
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
            "setSpeed", "Set Speed", .clip, exposure: .always,
            required: ["itemID", "speed"], properties: ["itemID": string, "speed": number]),
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
        command("timeline.describe", "Describe Timeline Structure", .timeline, kind: .read, exposure: .onDemand),
        command("audio.describe", "Describe Audio", .audio, kind: .read, exposure: .onDemand),
        command(
            "view.getFrame", "Get Frame", .view, kind: .confirm, exposure: .onDemand,
            required: ["at"], properties: ["at": number]),
        command(
            "listCommands", "List Commands", .app, kind: .read, exposure: .always,
            properties: ["category": string, "query": string]),
        command(
            "runCommand", "Run Command", .app, exposure: .always,
            required: ["id"], properties: ["id": string, "arguments": object]),
    ]

    /// Deliberately non-agent commands require a documented entry here.
    public static let explicitlyExcluded: [CommandID: String] = [
        "app.commandPalette": "Opening UI chrome has no useful assistant-side effect."
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
            command.agentExposure != .never
                && (category == nil || command.category == category)
                && (query?.isEmpty != false
                    || command.title.localizedCaseInsensitiveContains(query!)
                    || command.id.rawValue.localizedCaseInsensitiveContains(query!))
        }
    }

    private static let string: JSONValue = .object(["type": .string("string")])
    private static let number: JSONValue = .object(["type": .string("number")])
    private static let object: JSONValue = .object(["type": .string("object")])
    private static let point: JSONValue = typedObject(
        ["x": number, "y": number], required: ["x", "y"])
    private static let range: JSONValue = typedObject(
        ["start": number, "end": number], required: ["start", "end"])

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
