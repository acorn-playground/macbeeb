import BeebCore
import BeebHost
import CGtk
import Foundation
import Observation

private typealias ValuePicker<Value: Equatable> = PreferencesUI.ValuePicker<Value>

/// What game controllers do: a joystick, or keys, and the key each button
/// presses, for all discs or a disc's own. The buttons held on the first
/// controller show in the list, so it's clear which is which.
@MainActor
final class GamepadPreferences {
    let page = PreferencesPage(title: "Gamepad", icon: "input-gaming-symbolic")

    /// A button's rows: its key, or (in joystick mode, for the stick and
    /// fire buttons) "Joystick".
    private struct ButtonRows {
        let button: GamepadButton
        let key: ValuePicker<BeebKey?>
        let joystick: ActionRow
    }

    init() {
        let settings = GamepadSettings.shared, keyboard = KeyboardSettings.shared
        let discs = DiscPicker()
        let mode = ValuePicker<GamepadMode?>("Controller is") { mode in
            let disc = keyboard.editingDisc
            guard settings.config(for: disc).mode != mode else { return }
            settings.setMode(mode, disc: disc)
        }
        let explanation = PreferencesUI.footnote("")
        let controller = PreferencesGroup {
            discs.picker.row
            mode.row
        }
        controller.add(explanation)

        let buttons = PreferencesGroup(title: "Buttons", description: "Press a button to see which it is.")
        let catalogue = BeebKey.catalogue.map { (title: $0.name, value: Optional($0.key)) }
        let rows = GamepadButton.allCases.map { button in
            let key = ValuePicker<BeebKey?>(button.name, searchable: true) { key in
                let disc = keyboard.editingDisc
                guard settings.config(for: disc).key(for: button) != key else { return }
                settings.setKey(key, for: button, disc: disc)
            }
            let joystick = ActionRow(button.name).suffix(Label("Joystick", style: "dim-label"))
            buttons.add(key.row)
            buttons.add(joystick)
            return ButtonRows(button: button, key: key, joystick: joystick)
        }

        let reset = ButtonRow("Reset") { settings.reset(disc: keyboard.editingDisc) }
        let resetGroup = PreferencesGroup { reset }

        page.add(controller)
        page.add(buttons)
        page.add(resetGroup)

        page.track {
            let disc = keyboard.editingDisc
            let config = settings.config(for: disc)
            let current = settings.mapping(disc: disc).mode
            let modes = GamepadMode.allCases.map { (title: $0.name, value: Optional($0)) }
            let inherit = disc == nil ? [] : [(title: "As for all discs (\(settings.config.mode?.name ?? "Joystick"))",
                                               value: GamepadMode?.none)]
            mode.set(inherit + modes, selected: config.mode)
            explanation.text = current == .joystick
                ? "The first controller is joystick 0 and the second joystick 1: the d-pad or left stick moves it, and A or the right trigger fires. Other buttons press the keys below."
                : "Each button, and each direction of the d-pad and left stick, presses the key below."
            for row in rows {
                let isJoystick = current == .joystick && row.button.isJoystick
                row.key.row.isVisible = !isJoystick
                row.joystick.isVisible = isJoystick
                let none = disc == nil ? "None" : "As for all discs (\(settings.config.key(for: row.button)?.name ?? "none"))"
                row.key.set([(title: none, value: nil)] + catalogue, selected: config.key(for: row.button))
            }
            adw_preferences_row_set_title(cast(reset.widget), disc == nil ? "Reset" : "Remove This Disc’s Settings")
            reset.isEnabled = disc == nil ? config != GamepadSettings.Config(mode: .joystick) : !config.isEmpty
        }
        // The buttons held, as they're pressed.
        page.track {
            let held = settings.held
            for row in rows {
                let on = held.contains(row.button)
                row.key.row.setStyle("macbeeb-held", on)
                row.joystick.setStyle("macbeeb-held", on)
            }
        }
    }
}
