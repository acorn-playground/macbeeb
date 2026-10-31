import CGtk
import Foundation

// Menus (GMenu models, shown by menu buttons and popovers) and the actions
// their items run (GActions on the app or a window).
//
//     Menu {
//         MenuSection {
//             MenuItem("Open Disc…", "win.open-disc", accel: "<Alt>o")
//             MenuItem("Disc Drive Sounds", "win.drive-sounds")   // a toggle action: a check
//         }
//         Submenu("Model") {
//             for model in BBCMicro.Model.allCases {
//                 MenuItem(model.displayName, "win.model", target: model.rawValue)   // a radio
//             }
//         }
//     }

enum MenuEntry {
    case item(label: String, action: String, target: String?, accel: String?)
    case section(label: String?, entries: [MenuEntry])
    case submenu(label: String, entries: [MenuEntry])
    /// A menu that changes (`Menu.set`), as a submenu or a section.
    case live(label: String?, menu: Menu, submenu: Bool)
}

@resultBuilder
enum MenuList {
    static func buildExpression(_ entry: MenuEntry) -> [MenuEntry] { [entry] }
    static func buildExpression(_ entries: [MenuEntry]) -> [MenuEntry] { entries }
    static func buildBlock(_ parts: [MenuEntry]...) -> [MenuEntry] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [MenuEntry]?) -> [MenuEntry] { part ?? [] }
    static func buildEither(first: [MenuEntry]) -> [MenuEntry] { first }
    static func buildEither(second: [MenuEntry]) -> [MenuEntry] { second }
    static func buildArray(_ parts: [[MenuEntry]]) -> [MenuEntry] { parts.flatMap { $0 } }
}

func MenuItem(_ label: String, _ action: String, target: String? = nil, accel: String? = nil) -> MenuEntry {
    .item(label: label, action: action, target: target, accel: accel)
}

func MenuSection(_ label: String? = nil, @MenuList _ entries: () -> [MenuEntry]) -> MenuEntry {
    .section(label: label, entries: entries())
}

func Submenu(_ label: String, @MenuList _ entries: () -> [MenuEntry]) -> MenuEntry {
    .submenu(label: label, entries: entries())
}

/// A submenu whose items change as `menu.set` replaces them.
@MainActor
func Submenu(_ label: String, live menu: Menu) -> MenuEntry {
    .live(label: label, menu: menu, submenu: true)
}

/// A section whose items change as `menu.set` replaces them.
@MainActor
func MenuSection(live menu: Menu) -> MenuEntry {
    .live(label: nil, menu: menu, submenu: false)
}

@MainActor
final class Menu {
    let model: OpaquePointer

    init(@MenuList _ entries: () -> [MenuEntry]) {
        model = g_menu_new()
        Self.fill(model, entries())
    }

    init(entries: [MenuEntry]) {
        model = g_menu_new()
        Self.fill(model, entries)
    }

    /// Replaces the entries (a menu that changes, such as recent discs).
    func set(_ entries: [MenuEntry]) {
        g_menu_remove_all(model)
        Self.fill(model, entries)
    }

    private static func fill(_ menu: OpaquePointer, _ entries: [MenuEntry]) {
        for entry in entries {
            switch entry {
            case .item(let label, let action, let target, let accel):
                let item = g_menu_item_new(label, nil)!
                if let target {
                    macbeeb_menu_item_set_string_target(item, action, target)
                } else {
                    g_menu_item_set_detailed_action(item, action)
                }
                if let accel {
                    macbeeb_menu_item_set_attribute_string(item, "accel", accel)
                }
                g_menu_append_item(menu, item)
                g_object_unref(gpointer(item))
            case .section(let label, let entries):
                let section = g_menu_new()!
                fill(section, entries)
                g_menu_append_section(menu, label, UnsafeMutablePointer(section))
                g_object_unref(gpointer(section))
            case .submenu(let label, let entries):
                let submenu = g_menu_new()!
                fill(submenu, entries)
                g_menu_append_submenu(menu, label, UnsafeMutablePointer(submenu))
                g_object_unref(gpointer(submenu))
            case .live(let label, let live, let submenu):
                if submenu {
                    g_menu_append_submenu(menu, label, UnsafeMutablePointer(live.model))
                } else {
                    g_menu_append_section(menu, label, UnsafeMutablePointer(live.model))
                }
            }
        }
    }
}

/// A GAction: a command (activated), a toggle (a boolean state: a check in
/// a menu), or a choice (a string state: radio items, each with its value
/// as the target).
@MainActor
final class Action {
    let gAction: OpaquePointer
    let name: String

    /// A command.
    init(_ name: String, _ body: @escaping @MainActor () -> Void) {
        self.name = name
        gAction = g_simple_action_new(name, nil)
        GObjectRef(gAction).onPointer("activate") { _ in body() }
    }

    /// A toggle: `set` gets the new value when it's chosen.
    init(toggle name: String, isOn: Bool, _ set: @escaping @MainActor (Bool) -> Void) {
        self.name = name
        gAction = g_simple_action_new_stateful(name, nil, g_variant_new_boolean(isOn ? 1 : 0))
        let action = gAction
        GObjectRef(gAction).onPointer("activate") { _ in
            let state = g_action_get_state(action)
            let on = state.map { g_variant_get_boolean($0) != 0 } ?? false
            if let state { g_variant_unref(state) }
            set(!on)
        }
    }

    /// A choice: `set` gets the value of the item chosen.
    init(choice name: String, value: String, _ set: @escaping @MainActor (String) -> Void) {
        self.name = name
        gAction = g_simple_action_new_stateful(name, macbeeb_variant_type_string(), g_variant_new_string(value))
        GObjectRef(gAction).onPointer("activate") { parameter in
            guard let parameter else { return }
            let variant = OpaquePointer(parameter)
            set(String(cString: g_variant_get_string(variant, nil)))
        }
    }

    var isEnabled: Bool {
        get { g_action_get_enabled(gAction) != 0 }
        set {
            guard newValue != isEnabled else { return }
            g_simple_action_set_enabled(gAction, newValue ? 1 : 0)
        }
    }

    /// A toggle's state.
    var isOn: Bool {
        get {
            guard let state = g_action_get_state(gAction) else { return false }
            defer { g_variant_unref(state) }
            return g_variant_get_boolean(state) != 0
        }
        set {
            guard newValue != isOn else { return }
            g_simple_action_set_state(gAction, g_variant_new_boolean(newValue ? 1 : 0))
        }
    }

    /// A choice's state.
    var value: String {
        get {
            guard let state = g_action_get_state(gAction) else { return "" }
            defer { g_variant_unref(state) }
            return String(cString: g_variant_get_string(state, nil))
        }
        set {
            guard newValue != value else { return }
            g_simple_action_set_state(gAction, g_variant_new_string(newValue))
        }
    }
}
