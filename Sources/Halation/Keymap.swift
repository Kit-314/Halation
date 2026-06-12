import AppKit
import SwiftUI

/// Every remappable action in the viewer.
enum KeyAction: String, CaseIterable, Codable, Identifiable {
    case nextPhoto, previousPhoto, firstPhoto, lastPhoto
    case toggleFullscreen
    case zoomIn, zoomOut, zoomFit, zoomActual, zoom200, zoom300
    case rotateCW, rotateCCW
    case toggleInfo, toggleFilmstrip, toggleSlideshow, toggleHUD, toggleHelp
    case moveToTrash
    case toggleEdit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nextPhoto: "Next photo"
        case .previousPhoto: "Previous photo"
        case .firstPhoto: "First photo"
        case .lastPhoto: "Last photo"
        case .toggleFullscreen: "Toggle full screen"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .zoomFit: "Zoom to fit"
        case .zoomActual: "Zoom 100%"
        case .zoom200: "Zoom 200%"
        case .zoom300: "Zoom 300%"
        case .rotateCW: "Rotate clockwise"
        case .rotateCCW: "Rotate counterclockwise"
        case .toggleInfo: "Info panel"
        case .toggleFilmstrip: "Filmstrip"
        case .toggleSlideshow: "Slideshow"
        case .toggleHUD: "Show/hide toolbar"
        case .toggleHelp: "Shortcut help"
        case .moveToTrash: "Move to Trash"
        case .toggleEdit: "Edit mode"
        }
    }
}

/// A single key press: special keys match by key code, printable keys by
/// character (so remaps survive keyboard-layout differences).
struct KeyStroke: Codable, Hashable {
    var keyCode: UInt16
    var character: String?
    var shift: Bool

    static let specialKeyCodes: Set<UInt16> = [
        36,  // return
        48,  // tab
        49,  // space
        51,  // delete
        117, // forward delete
        115, 119, 116, 121,      // home, end, pgup, pgdn
        123, 124, 125, 126,      // ← → ↓ ↑
    ]

    var isSpecial: Bool { Self.specialKeyCodes.contains(keyCode) }

    static func from(_ event: NSEvent) -> KeyStroke {
        let shift = event.modifierFlags.contains(.shift)
        if specialKeyCodes.contains(event.keyCode) {
            return KeyStroke(keyCode: event.keyCode, character: nil, shift: shift)
        }
        let char = event.charactersIgnoringModifiers ?? ""
        return KeyStroke(keyCode: event.keyCode, character: char.lowercased(), shift: false)
    }

    func matches(_ event: NSEvent) -> Bool {
        if isSpecial {
            return event.keyCode == keyCode
                && event.modifierFlags.contains(.shift) == shift
        }
        guard let character, !character.isEmpty else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == character
    }

    var display: String {
        if isSpecial {
            let name: String
            switch keyCode {
            case 36: name = "↩"
            case 48: name = "⇥"
            case 49: name = "Space"
            case 51: name = "⌫"
            case 117: name = "⌦"
            case 115: name = "Home"
            case 119: name = "End"
            case 116: name = "PgUp"
            case 121: name = "PgDn"
            case 123: name = "←"
            case 124: name = "→"
            case 125: name = "↓"
            case 126: name = "↑"
            default: name = "Key \(keyCode)"
            }
            return shift ? "⇧\(name)" : name
        }
        return (character ?? "?").uppercased()
    }
}

/// User-remappable keyboard map, persisted to UserDefaults as JSON.
@MainActor
final class Keymap: ObservableObject {
    @Published private(set) var bindings: [KeyAction: [KeyStroke]] = [:]

    private static let defaultsKey = "keymap.v1"

    static let factoryDefaults: [KeyAction: [KeyStroke]] = [
        .nextPhoto: [
            KeyStroke(keyCode: 124, character: nil, shift: false),   // →
            KeyStroke(keyCode: 125, character: nil, shift: false),   // ↓
            KeyStroke(keyCode: 49, character: nil, shift: false),    // space
            KeyStroke(keyCode: 121, character: nil, shift: false),   // pgdn
        ],
        .previousPhoto: [
            KeyStroke(keyCode: 123, character: nil, shift: false),   // ←
            KeyStroke(keyCode: 126, character: nil, shift: false),   // ↑
            KeyStroke(keyCode: 49, character: nil, shift: true),     // ⇧space
            KeyStroke(keyCode: 116, character: nil, shift: false),   // pgup
        ],
        .firstPhoto: [KeyStroke(keyCode: 115, character: nil, shift: false)],
        .lastPhoto: [KeyStroke(keyCode: 119, character: nil, shift: false)],
        .toggleFullscreen: [KeyStroke(keyCode: 3, character: "f", shift: false)],
        .zoomIn: [
            KeyStroke(keyCode: 24, character: "=", shift: false),
            KeyStroke(keyCode: 24, character: "+", shift: false),
        ],
        .zoomOut: [
            KeyStroke(keyCode: 27, character: "-", shift: false),
            KeyStroke(keyCode: 27, character: "_", shift: false),
        ],
        .zoomFit: [KeyStroke(keyCode: 29, character: "0", shift: false)],
        .zoomActual: [KeyStroke(keyCode: 18, character: "1", shift: false)],
        .zoom200: [KeyStroke(keyCode: 19, character: "2", shift: false)],
        .zoom300: [KeyStroke(keyCode: 20, character: "3", shift: false)],
        .rotateCW: [
            KeyStroke(keyCode: 15, character: "r", shift: false),
            KeyStroke(keyCode: 30, character: "]", shift: false),
        ],
        .rotateCCW: [KeyStroke(keyCode: 33, character: "[", shift: false)],
        .toggleInfo: [KeyStroke(keyCode: 34, character: "i", shift: false)],
        .toggleFilmstrip: [KeyStroke(keyCode: 17, character: "t", shift: false)],
        .toggleSlideshow: [KeyStroke(keyCode: 1, character: "s", shift: false)],
        .toggleHUD: [KeyStroke(keyCode: 4, character: "h", shift: false)],
        .toggleHelp: [
            KeyStroke(keyCode: 44, character: "?", shift: false),
            KeyStroke(keyCode: 44, character: "/", shift: false),
        ],
        .moveToTrash: [
            KeyStroke(keyCode: 51, character: nil, shift: false),
            KeyStroke(keyCode: 117, character: nil, shift: false),
        ],
        .toggleEdit: [KeyStroke(keyCode: 14, character: "e", shift: false)],
    ]

    init() {
        load()
    }

    func action(for event: NSEvent) -> KeyAction? {
        for (action, strokes) in bindings {
            if strokes.contains(where: { $0.matches(event) }) { return action }
        }
        return nil
    }

    func strokes(for action: KeyAction) -> [KeyStroke] {
        bindings[action] ?? []
    }

    /// Adds a stroke to an action, stealing it from any other action first.
    func add(_ stroke: KeyStroke, to action: KeyAction) {
        for (other, strokes) in bindings where other != action {
            let filtered = strokes.filter { $0 != stroke }
            if filtered.count != strokes.count { bindings[other] = filtered }
        }
        var strokes = bindings[action] ?? []
        if !strokes.contains(stroke) { strokes.append(stroke) }
        bindings[action] = strokes
        save()
    }

    func remove(_ stroke: KeyStroke, from action: KeyAction) {
        bindings[action] = (bindings[action] ?? []).filter { $0 != stroke }
        save()
    }

    func reset(_ action: KeyAction) {
        bindings[action] = Self.factoryDefaults[action] ?? []
        save()
    }

    func resetAll() {
        bindings = Self.factoryDefaults
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [KeyStroke]].self, from: data) {
            var map: [KeyAction: [KeyStroke]] = [:]
            for (key, strokes) in decoded {
                if let action = KeyAction(rawValue: key) { map[action] = strokes }
            }
            // New actions added after the user saved a keymap get defaults.
            for action in KeyAction.allCases where map[action] == nil {
                map[action] = Self.factoryDefaults[action] ?? []
            }
            bindings = map
        } else {
            bindings = Self.factoryDefaults
        }
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
