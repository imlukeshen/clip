import CoreModel
import Foundation

/// The complete, provider-independent assistant tool surface.
public enum ToolCatalog {
    public static let all: [ToolSchema] = [
        schema("describeTimeline", "Describe the current timeline.", .read),
        schema(
            "describeClip", "Describe one clip.", .read, required: ["itemID"],
            properties: ["itemID": string]),
        schema(
            "trimClip", "Trim one clip to source seconds.", .write,
            required: ["itemID", "start", "end"],
            properties: ["itemID": string, "start": number, "end": number]),
        schema(
            "splitClip", "Split one clip at timeline seconds.", .write, required: ["itemID", "at"],
            properties: ["itemID": string, "at": number]),
        schema(
            "reorderClips", "Set the video clip order.", .write, required: ["order"],
            properties: ["order": array(string)]),
        schema(
            "setSpeed", "Set a clip playback speed.", .write, required: ["itemID", "speed"],
            properties: ["itemID": string, "speed": number]),
        schema(
            "addZoom", "Add a clip-local zoom.", .write,
            required: ["itemID", "range", "center", "scale"],
            properties: ["itemID": string, "range": range, "center": point, "scale": number]),
        schema(
            "autoZoomFromClicks", "Generate zooms from recorded clicks.", .write,
            required: ["itemIDs"], properties: ["itemIDs": array(string), "options": object]),
        schema(
            "removeEffect", "Remove one effect.", .write, required: ["itemID", "effectID"],
            properties: ["itemID": string, "effectID": string]),
        schema(
            "setBackground", "Set clip backgrounds.", .write,
            required: ["itemIDs", "padding", "radius", "style"],
            properties: [
                "itemIDs": array(string), "padding": number, "radius": number, "style": object,
            ]),
        schema(
            "detectSilence", "Find silent source ranges.", .read,
            required: ["itemIDs", "thresholdDB"],
            properties: ["itemIDs": array(string), "thresholdDB": number]),
        schema(
            "trimSilence", "Trim detected silence.", .write, required: ["itemIDs", "thresholdDB"],
            properties: ["itemIDs": array(string), "thresholdDB": number]),
        schema(
            "generateCaptions", "Generate on-device captions.", .write,
            required: ["itemIDs", "engine"],
            properties: ["itemIDs": array(string), "engine": string]),
        schema(
            "exportProject", "Export the project to a destination.", .confirm,
            required: ["preset", "destination"],
            properties: ["preset": string, "destination": string]),
        schema(
            "setPreference", "Change an application preference.", .confirm,
            required: ["key", "value"], properties: ["key": string, "value": object]),
    ]

    public static func schema(named name: String) -> ToolSchema? {
        all.first { $0.name == name }
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

    private static func typedObject(_ properties: [String: JSONValue], required: [String])
        -> JSONValue
    {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func schema(
        _ name: String,
        _ description: String,
        _ kind: ToolKind,
        required: [String] = [],
        properties: [String: JSONValue] = [:]
    ) -> ToolSchema {
        ToolSchema(
            name: name,
            description: description,
            kind: kind,
            parameters: typedObject(properties, required: required)
        )
    }
}
