# CoreModel

`CoreModel` owns clipx's deterministic document graph, time representation,
effects, event sidecars, JSON interchange, and transactional patch engine. It
imports Foundation only and must never depend on UI, storage, or media
frameworks. Two files currently also import CoreGraphics for geometry types;
that is known drift from this rule, not a precedent.
