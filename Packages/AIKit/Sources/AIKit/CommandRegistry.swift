import CoreModel
import Foundation

public struct CommandID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum CommandCategory: String, Codable, Sendable, CaseIterable {
    case asset, clip, effect, audio, timeline, image, pdf, text, file, view, app
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

/// The single capability catalog for clipx's user and assistant surfaces.
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
            "capture.history", "Open clipx Clipboard", .app,
            shortcut: .init("c", modifiers: ["command", "shift"]), kind: .read, exposure: .never),
        command(
            "capture.clearHistory", "Clear clipx Clipboard", .app, destructive: true,
            kind: .confirm, exposure: .onDemand),
        command("edit.undo", "Undo", .app, exposure: .onDemand),
        command("edit.redo", "Redo", .app, exposure: .onDemand),
        command(
            "edit.delete", "Delete Selection", .app, destructive: true,
            description:
                "Delete the selected element in the open editor: timeline items, an image layer, or a PDF edit.",
            kind: .confirm, exposure: .onDemand),
        command("asset.selectAll", "Select All", .asset, shortcut: .init("a"), exposure: .onDemand),
        command(
            "asset.deselectAll", "Deselect All", .asset,
            shortcut: .init("a", modifiers: ["command", "shift"]), exposure: .onDemand),
        command(
            "asset.search", "Search Library", .asset,
            shortcut: .init("f"), kind: .confirm, exposure: .onDemand),
        command(
            "search.library", "Search Library Content", .asset,
            description:
                "Search the full local library with optional filters. Results include asset IDs, timeline item IDs when open, timestamped moments, and snippets. Quoted text forces exact matching.",
            kind: .read,
            exposure: .always,
            required: ["text"],
            properties: [
                "text": string, "kind": string("video, image, audio, document, or text"),
                "after": string("YYYY-MM-DD"), "before": string("YYYY-MM-DD"),
                "folder": string, "minimumDuration": number("Seconds"),
                "maximumDuration": number("Seconds"), "hasAudio": boolean,
                "mode": string("auto, keyword, or semantic"), "limit": number,
            ]),
        command(
            "search.withinAsset", "Search Within Asset", .asset,
            description:
                "Find exact timestamped moments inside one asset. Results include source timestamps and the corresponding open timeline item IDs. Quoted text forces exact matching.",
            kind: .read,
            exposure: .always,
            required: ["assetID", "text"],
            properties: ["assetID": string, "text": string]),
        command(
            "search.textAt", "Read Text at Timestamp", .asset,
            description:
                "Return OCR text spans and bounding boxes visible at a source timestamp in an asset. Use this to copy or reason about exact on-screen text.",
            kind: .read,
            exposure: .always,
            required: ["assetID", "time"],
            properties: ["assetID": string, "time": number("Seconds into the source media")]),
        command(
            "search.similar", "Find Similar Assets", .asset,
            description:
                "Find semantic nearest neighbours to an asset. Results include asset IDs, timestamped moments, and snippets; quoted search text is exact in the other search tools.",
            kind: .read,
            exposure: .always,
            required: ["assetID"],
            properties: ["assetID": string, "limit": number]),
        command(
            "convert.listTargets", "List Conversion Targets", .file,
            description:
                "List the conversion formats that every supplied library asset can reach. Use asset IDs returned by library search.",
            kind: .read,
            exposure: .always,
            required: ["assetIDs"],
            properties: ["assetIDs": array(string)]),
        command(
            "convert.plan", "Plan Conversion", .file,
            description:
                "Plan a conversion without writing files. Reports the backend route, lossy or lossless tradeoff, warnings, and size or resize constraints.",
            kind: .read,
            exposure: .always,
            required: ["assetIDs", "target"],
            properties: [
                "assetIDs": array(string), "target": string, "preset": string,
                "quality": number("0 to 1"), "longestSide": number("Pixels; images only"),
                "maximumBytes": number, "stripMetadata": boolean,
            ]),
        command(
            "convert.presets", "List Conversion Presets", .file,
            description:
                "List built-in conversion presets with their target format and important tradeoffs.",
            kind: .read,
            exposure: .always),
        command(
            "convert.run", "Run Conversion", .file,
            description:
                "Write converted copies after explicit user confirmation. Call convert.plan first. destination is an optional absolute folder path; otherwise clipx uses the configured export folder.",
            kind: .confirm,
            exposure: .always,
            required: ["assetIDs", "target"],
            properties: [
                "assetIDs": array(string), "target": string, "preset": string,
                "quality": number("0 to 1"), "longestSide": number("Pixels; images only"),
                "maximumBytes": number, "stripMetadata": boolean, "destination": string,
                "filenameTemplate": string,
                "conflictPolicy": string("rename, overwrite, or skip"),
            ]),
        command(
            "text.create", "Create Text Buffer", .text,
            description:
                "Create and open a persistent scratch text buffer, optionally with initial content, a safe filename, and an explicit language.",
            exposure: .always,
            properties: ["name": string, "language": string, "contents": string]),
        command(
            "text.setLanguage", "Set Text Language", .text,
            description:
                "Set the explicit syntax language for the active text file. Use a LanguageID such as markdown, latex, swift, json, or plainText.",
            exposure: .always,
            required: ["language"],
            properties: ["language": string]),
        command(
            "text.format", "Format Text", .text,
            description:
                "Apply deterministic edits to the active text file. Supply complete contents or non-overlapping one-based inclusive line edits; optional cleanup trims trailing whitespace or normalizes line endings.",
            exposure: .always,
            properties: [
                "file": string,
                "contents": string,
                "edits": array(
                    typedObject(
                        ["startLine": number, "endLine": number, "replacement": string],
                        required: ["startLine", "endLine", "replacement"]
                    )
                ),
                "trimTrailingWhitespace": boolean,
                "lineEnding": string,
            ]),
        command(
            "tex.compile", "Compile LaTeX", .text,
            description:
                "Compile the active LaTeX project in clipx's confined TeX workspace and wait for success or diagnostics.",
            exposure: .always),
        command(
            "tex.diagnostics", "Read LaTeX Diagnostics", .text,
            description:
                "Read structured diagnostics and bounded source context from the most recent LaTeX compile.",
            kind: .read,
            exposure: .always),
        command(
            "text.export", "Export Text", .text,
            description:
                "Write the active file as a self-contained syntax-colored HTML, RTF, or plain-text file. destination must be an absolute file path.",
            kind: .confirm,
            exposure: .always,
            required: ["format", "destination"],
            properties: ["format": string, "destination": string]),
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
            "trimClip", "Trim Clip", .clip,
            description:
                "Set which part of its source media a clip plays. On the main track, later clips shift to stay adjacent.",
            exposure: .always,
            required: ["itemID", "start", "end"],
            properties: [
                "itemID": string,
                "start": number("Seconds into the source media where the clip begins"),
                "end": number("Seconds into the source media where the clip ends"),
            ]),
        command(
            "splitClip", "Split Clip", .clip,
            shortcut: .init("k", modifiers: ["command", "shift"]),
            description: "Cut one clip into two at a point on the timeline.",
            exposure: .always,
            required: ["itemID", "at"],
            properties: [
                "itemID": string,
                "at": number(
                    "Seconds from the start of the project, at least 0.4 inside the clip"),
            ]),
        command(
            "reorderClips", "Reorder Clips", .timeline, exposure: .always,
            required: ["order"],
            properties: [
                "order": described(array(string), "Clip IDs from one track, in their new order")
            ]),
        command(
            "timeline.toggleSnapping", "Toggle Snapping", .timeline,
            shortcut: .init("s", modifiers: []), kind: .confirm, exposure: .onDemand),
        command(
            "timeline.rippleDelete", "Ripple Delete", .timeline,
            shortcut: .init("delete", modifiers: ["shift"]), destructive: true,
            description: "Delete a clip from the main track and close the gap it leaves.",
            exposure: .onDemand, required: ["itemID"], properties: ["itemID": string]),
        command(
            "timeline.roll", "Roll Edit", .timeline,
            description: "Move the cut between this clip and the next one.",
            exposure: .onDemand,
            required: ["itemID", "delta"],
            properties: [
                "itemID": string, "delta": number("Seconds; positive moves the cut later"),
            ]),
        command(
            "timeline.slip", "Slip Clip", .timeline,
            description: "Change which part of the source a clip shows without moving it.",
            exposure: .onDemand,
            required: ["itemID", "delta"],
            properties: [
                "itemID": string,
                "delta": number("Seconds of source; positive shows later material"),
            ]),
        command(
            "timeline.slide", "Slide Clip", .timeline,
            description: "Move a clip between its two neighbours, which resize to fit.",
            exposure: .onDemand,
            required: ["itemID", "delta"],
            properties: [
                "itemID": string, "delta": number("Seconds; positive moves the clip later"),
            ]),
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
            properties: [
                "time": number("Seconds from the start of the project; defaults to the playhead"),
                "name": string,
            ]),
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
            shortcut: .init("d"),
            description: "Dissolve from this clip into the next one.",
            exposure: .onDemand,
            required: ["itemID", "duration"],
            properties: ["itemID": string, "duration": number("Seconds")]),
        command(
            "timeline.audioFade", "Set Audio Fade", .audio, exposure: .onDemand,
            required: ["itemID", "fadeIn", "fadeOut"],
            properties: [
                "itemID": string, "fadeIn": number("Seconds"), "fadeOut": number("Seconds"),
            ]),
        command(
            "timeline.setTrackState", "Set Track State", .timeline, exposure: .onDemand,
            required: ["trackID", "property", "value"],
            properties: [
                "trackID": string, "property": string("enabled, locked, muted, or solo"),
                "value": boolean,
            ]),
        command(
            "setSpeed", "Set Speed", .clip, exposure: .always,
            required: ["itemID", "speed"],
            properties: [
                "itemID": string, "speed": number("Rate multiplier; 1 is normal, 2 is double"),
            ]),
        command(
            "setKeyframe", "Set Keyframe", .effect,
            description:
                "Animate a property at a moment. opacity and transform need itemID; gain needs trackID; blurRadius and zoomScale need itemID and effectID.",
            exposure: .always,
            required: ["property", "time", "value"],
            properties: [
                "property": string("opacity, gain, transform, blurRadius, or zoomScale"),
                "time": number(
                    "Seconds from the start of the clip; for gain, from the start of the project"),
                "value": described(
                    keyframeValue,
                    "A number (opacity 0 to 1, gain in decibels), or for transform an object with translationX, translationY, scaleX, scaleY, rotationDegrees"
                ),
                "itemID": string, "trackID": string, "effectID": string,
                "easing": string("linear, smoothstep, or easeInOut"),
            ]),
        command(
            "addZoom", "Add Zoom", .effect,
            description: "Zoom into part of the frame for part of a clip.",
            exposure: .always,
            required: ["itemID", "range", "center", "scale"],
            properties: [
                "itemID": string,
                "range": described(range, "Seconds from the start of the clip"),
                "center": described(point, "Fractions 0 to 1 of the frame width and height"),
                "scale": number("Magnification; 2 doubles the size"),
            ]),
        command(
            "autoZoomFromClicks", "Auto Zoom from Clicks", .effect,
            description: "Add zooms around the mouse clicks recorded with each clip.",
            exposure: .always,
            required: ["itemIDs"],
            properties: [
                "itemIDs": array(string),
                "options": described(
                    object,
                    "Optional: clusterWindow, leadIn, holdOut, minGap in seconds; scale; maxPerMinute"
                ),
            ]),
        command(
            "removeEffect", "Remove Effect", .effect, destructive: true, exposure: .always,
            required: ["itemID", "effectID"],
            properties: ["itemID": string, "effectID": string]),
        command(
            "setBackground", "Set Background", .effect, exposure: .always,
            required: ["itemIDs", "padding", "radius", "style"],
            properties: [
                "itemIDs": array(string), "padding": number, "radius": number,
                "style": described(
                    object,
                    "Either {color: {r, g, b, a}} with channels 0 to 1, or {assetID} for an image"),
            ]),
        command(
            "detectSilence", "Detect Silence", .audio, kind: .read, exposure: .onDemand,
            required: ["itemIDs", "thresholdDB"],
            properties: ["itemIDs": array(string), "thresholdDB": silenceThreshold]),
        command(
            "trimSilence", "Trim Silence", .audio,
            description: "Trim the silence from the start and end of each clip.",
            exposure: .always,
            required: ["itemIDs", "thresholdDB"],
            properties: ["itemIDs": array(string), "thresholdDB": silenceThreshold]),
        command(
            "generateCaptions", "Generate Captions", .audio, exposure: .always,
            required: ["itemIDs", "engine"],
            properties: ["itemIDs": array(string), "engine": string("Must be onDevice")]),
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
            "cropTo", "Crop Image", .image,
            description: "Crop the image to an aspect ratio or to a rectangle. Give one.",
            exposure: .onDemand,
            properties: ["aspect": string("Such as 16:9 or square"), "rect": imageRect]),
        command(
            "addAnnotation", "Add Image Annotation", .image, exposure: .onDemand,
            required: ["type", "rect"],
            properties: [
                "type": string("arrow, box, ellipse, text, highlight, or step"),
                "rect": imageRect, "text": string,
            ]),
        command(
            "suggestRedactions", "Suggest Image Redactions", .image,
            kind: .read, exposure: .onDemand),
        command(
            "applyRedactions", "Apply Suggested Redactions", .image, exposure: .onDemand,
            required: ["suggestionIDs"], properties: ["suggestionIDs": array(string)]),
        command(
            "addPadding", "Add Image Padding", .image, exposure: .onDemand,
            properties: [
                "amount": number("Fraction of the image size, such as 0.08"),
                "color": described(object, "r, g, b, a channels, each 0 to 1"),
            ]),
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
                "pageID": pageID, "text": string, "rect": pageRect, "fontSize": number,
            ]),
        command(
            "pdf.highlight", "Highlight PDF Region", .pdf, exposure: .onDemand,
            required: ["rect"], properties: ["pageID": pageID, "rect": pageRect]),
        command(
            "pdf.redact", "Redact PDF Region", .pdf, destructive: true, exposure: .onDemand,
            required: ["rect"], properties: ["pageID": pageID, "rect": pageRect]),
        command(
            "pdf.findText", "Find PDF Text", .pdf,
            description:
                "Locate every occurrence of a string and return its page and rectangle. Call this before pdf.redact or pdf.highlight, which need a rectangle.",
            kind: .read, exposure: .onDemand,
            required: ["text"], properties: ["text": string, "pageID": pageID]),
        command(
            "pdf.redactText", "Redact PDF Text", .pdf, destructive: true,
            description:
                "Redact every occurrence of a string. Prefer this over pdf.redact when the user names the text to hide rather than a region.",
            exposure: .onDemand,
            required: ["text"], properties: ["text": string, "pageID": pageID]),
        command(
            "pdf.rotatePage", "Rotate PDF Page", .pdf,
            description: "Rotate a page a quarter turn clockwise.",
            exposure: .onDemand,
            properties: ["pageID": pageID]),
        command(
            "pdf.reorderPage", "Reorder PDF Page", .pdf, exposure: .onDemand,
            required: ["destination"],
            properties: [
                "pageID": pageID,
                "destination": number("New position, counting from 0 for the first page"),
            ]),
        command(
            "pdf.ocrPage", "Recognize PDF Page Text", .pdf, exposure: .onDemand,
            properties: ["pageID": pageID]),
        command(
            "pdf.toMarkdown", "Convert PDF to Markdown", .pdf,
            kind: .read, exposure: .onDemand),
        command(
            "listCommands", "List Commands", .app,
            description: "List commands that are not offered directly, to run with runCommand.",
            kind: .read, exposure: .always,
            properties: [
                "category": string(
                    "asset, clip, effect, audio, timeline, image, pdf, text, file, view, or app"),
                "query": string,
            ]),
        command(
            "runCommand", "Run Command", .app,
            description: "Run a command found with listCommands.",
            exposure: .always,
            required: ["id"],
            properties: [
                "id": string("A command ID returned by listCommands"), "arguments": object,
            ]),
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
    private static let silenceThreshold = number(
        "Decibels below which audio counts as silence, such as -38")
    private static let imageRect = described(rect, "Fractions 0 to 1 of the image")
    private static let pageRect = described(
        rect, "Fractions 0 to 1 of the page, measured from its top-left corner")
    private static let pageID = string("Defaults to the selected page")

    // A bare type tells a model that `start` is a number and nothing else. The
    // unit and the reference point — seconds, and of the source or of the
    // project — are what it gets wrong, so they are stated where it reads them.
    private static func string(_ description: String) -> JSONValue {
        described(string, description)
    }

    private static func number(_ description: String) -> JSONValue {
        described(number, description)
    }

    private static func described(_ schema: JSONValue, _ description: String) -> JSONValue {
        guard case .object(var fields) = schema else { return schema }
        fields["description"] = .string(description)
        return .object(fields)
    }

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
        description: String? = nil,
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
                description: description ?? title,
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

    /// The always-exposed tools plus the on-demand ones for `categories`.
    ///
    /// On-demand tools are reachable only through meta-tool discovery, which
    /// costs a round trip and asks the model to find a name it was never shown.
    /// A capable model manages it; a small local one does not, which is how
    /// "redact this word" in the PDF workspace became a long wait and nothing
    /// happening — `pdf.redact` exists, but was never offered. Tools for the
    /// workspace that is actually open are worth their place in the list.
    public static func all(expanding categories: Set<CommandCategory>) -> [ToolSchema] {
        CommandRegistry.all.compactMap { command in
            switch command.agentExposure {
            case .always: command.schema
            case .onDemand: categories.contains(command.category) ? command.schema : nil
            case .never: nil
            }
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
