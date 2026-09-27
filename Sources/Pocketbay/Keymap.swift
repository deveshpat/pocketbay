import Foundation

enum ControlType: String, Codable, CaseIterable {
    case tap        // hold a key → hold a finger on this spot
    case joystick   // four direction keys drive a virtual stick
    case aim        // toggle key turns mouse movement into camera drags
    case fire       // mouse button fires while aiming
    case look       // hold a key to free-look with the mouse while aiming

    var title: String {
        switch self {
        case .tap: return "Button"
        case .joystick: return "Joystick"
        case .aim: return "Mouse aim"
        case .fire: return "Fire"
        case .look: return "Free look"
        }
    }

    var symbol: String {
        switch self {
        case .tap: return "hand.tap"
        case .joystick: return "dpad"
        case .aim: return "scope"
        case .fire: return "flame"
        case .look: return "eye"
        }
    }
}

/// One mapped control. Positions are normalised (0…1) to the Android screen so a
/// layout survives resolution changes.
struct Control: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: ControlType
    var x: Double
    var y: Double
    var key: InputKey?
    /// Joystick directions in order: up, left, down, right.
    var keys: [InputKey]?
    /// Joystick: pushes the stick further up (sprint).
    var boostKey: InputKey?
    /// Joystick radius as a fraction of screen height.
    var radius: Double?
    /// Aim / free-look mouse sensitivity multiplier.
    var sensitivity: Double?
    var label: String?
    /// Button opens a menu (bag, map): pressing it during mouse aim shows the cursor,
    /// and pressing it again hides the cursor and resumes aim.
    var showsCursor: Bool?
    /// Hold-to-open: pressing the key taps the button (opens), releasing taps it again
    /// (closes). With showsCursor, aim pauses only while the key is held.
    var holdToOpen: Bool?
    /// When the control works: nil = always, or only on foot / only in a vehicle.
    var mode: ControlMode?
    /// Pressing it switches the controls mode (e.g. Drive/Exit vehicle → toggle).
    var switchesTo: ModeSwitch?

    static func == (a: Control, b: Control) -> Bool { a.id == b.id }

    /// Every input this control listens to.
    var inputs: [InputKey] {
        var out: [InputKey] = []
        if let key { out.append(key) }
        out += keys ?? []
        if let boostKey { out.append(boostKey) }
        return out
    }

    static func new(_ type: ControlType, x: Double = 0.5, y: Double = 0.5) -> Control {
        switch type {
        case .tap: return Control(type: .tap, x: x, y: y, key: nil, label: "Button")
        case .joystick:
            return Control(type: .joystick, x: x, y: y, keys: [.key(13), .key(0), .key(1), .key(2)],
                           boostKey: .key(56), radius: 0.12, label: "Move")
        case .aim: return Control(type: .aim, x: x, y: y, key: .key(50), sensitivity: 1.0, label: "Mouse aim")
        case .fire: return Control(type: .fire, x: x, y: y, key: .mouse(0), label: "Fire")
        case .look: return Control(type: .look, x: x, y: y, key: .key(58), sensitivity: 1.0, label: "Free look")
        }
    }
}

enum ControlMode: String, Codable, CaseIterable {
    case foot, vehicle
    var title: String { self == .foot ? "On foot" : "In vehicle" }
}

enum ModeSwitch: String, Codable {
    case foot, vehicle, toggle
}

struct Keymap: Codable {
    var id = UUID()
    var name: String
    /// Android packages this layout applies to; empty = every app.
    var packages: [String]
    var controls: [Control]
    /// Toggles between on-foot and vehicle controls.
    var vehicleToggleKey: InputKey?

    init(id: UUID = UUID(), name: String, packages: [String], controls: [Control], vehicleToggleKey: InputKey? = .key(9)) {
        self.id = id
        self.name = name
        self.packages = packages
        self.controls = controls
        self.vehicleToggleKey = vehicleToggleKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()   // files from before layouts had ids
        name = try c.decode(String.self, forKey: .name)
        packages = try c.decode([String].self, forKey: .packages)
        controls = try c.decode([Control].self, forKey: .controls)
        vehicleToggleKey = try c.decodeIfPresent(InputKey.self, forKey: .vehicleToggleKey)
    }

    /// Default layout for BGMI's "Layout 2" HUD at 16:9, measured from the game's
    /// Customize Controls screen.
    static let bgmi = Keymap(name: "BGMI", packages: ["com.pubg.imobile"], controls: [
        // Shift pushes the stick ~1.9x further: far enough to reach the Sprint lock above it.
        Control(type: .joystick, x: 0.181, y: 0.690, keys: [.key(13), .key(0), .key(1), .key(2)],
                boostKey: .key(56), radius: 0.085, label: "Move"),
        Control(type: .aim, x: 0.746, y: 0.235, key: .key(50), sensitivity: 1.0, label: "Mouse aim"),
        Control(type: .fire, x: 0.850, y: 0.747, key: .mouse(0), label: "Fire"),
        Control(type: .look, x: 0.509, y: 0.515, key: .key(58), sensitivity: 1.0, label: "Free look"),
        Control(type: .tap, x: 0.960, y: 0.521, key: .mouse(1), label: "Scope"),
        Control(type: .tap, x: 0.954, y: 0.686, key: .key(49), label: "Jump"),
        Control(type: .tap, x: 0.854, y: 0.934, key: .key(8), label: "Crouch"),
        Control(type: .tap, x: 0.938, y: 0.940, key: .key(6), label: "Prone"),
        Control(type: .tap, x: 0.560, y: 0.362, key: .key(15), label: "Reload"),
        Control(type: .tap, x: 0.432, y: 0.905, key: .key(18), label: "Gun 1"),
        Control(type: .tap, x: 0.564, y: 0.905, key: .key(19), label: "Gun 2"),
        Control(type: .tap, x: 0.691, y: 0.937, key: .key(5), label: "Throw"),
        Control(type: .tap, x: 0.307, y: 0.934, key: .key(4), label: "Heal"),
        Control(type: .tap, x: 0.672, y: 0.686, key: .key(3), label: "Open door"),
        Control(type: .tap, x: 0.676, y: 0.539, key: .key(14), label: "Get in vehicle"),
        Control(type: .tap, x: 0.071, y: 0.909, key: .key(48), label: "Bag", showsCursor: true, holdToOpen: true),
        Control(type: .tap, x: 0.932, y: 0.127, key: .key(46), label: "Map", showsCursor: true, holdToOpen: true),
    ])
}

/// Saved layouts, one JSON file each in Application Support/Pocketbay/Layouts,
/// plus which one is active.
enum KeymapStore {
    private static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pocketbay", isDirectory: true)
    }

    private static var dir: URL {
        let d = baseDir.appendingPathComponent("Layouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(for id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    private static let activeKey = "activeLayout"

    /// All saved layouts, sorted by name. Creates the default one on first run, and
    /// imports the single keymap.json older versions wrote.
    static func all() -> [Keymap] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var maps = files.filter { $0.pathExtension == "json" }.compactMap { url -> Keymap? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Keymap.self, from: data)
        }
        if maps.isEmpty {
            let legacy = baseDir.appendingPathComponent("keymap.json")
            if let data = try? Data(contentsOf: legacy), let old = try? JSONDecoder().decode(Keymap.self, from: data) {
                maps = [old]
                try? FileManager.default.removeItem(at: legacy)
            } else {
                maps = [.bgmi]
            }
            maps.forEach(save)
        }
        return maps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func active() -> Keymap {
        let maps = all()
        let id = UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init)
        return maps.first { $0.id == id } ?? maps[0]
    }

    static func setActive(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
    }

    static func save(_ map: Keymap) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(map) { try? data.write(to: url(for: map.id), options: .atomic) }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
