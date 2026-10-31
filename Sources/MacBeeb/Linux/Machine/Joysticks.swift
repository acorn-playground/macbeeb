import BeebHost
import CGtk
import CSDL3
import Foundation
import Observation

/// Connects game controllers (through SDL) to the BBC in the window in
/// front: the first controller is joystick 0 (left stick or d-pad, A to
/// fire), the second is joystick 1, or they press keys, as
/// `GamepadSettings` says for the disc in its drive 0. (The Mac's uses the
/// GameController framework; the mapping is shared.)
@MainActor
final class Joysticks {
    static let shared = Joysticks()

    /// The machine the controllers drive: the last one whose window was
    /// active. Changing it lets go of everything held on the old one.
    weak var machine: MachineController? {
        willSet {
            guard newValue !== machine else { return }
            for index in mappers.indices {
                send(mappers[index].reset(), index)
            }
        }
        didSet {
            if oldValue !== machine {
                updateMapping()
            }
        }
    }

    /// By controller.
    private var mappers: [GamepadMapper] = [GamepadMapper(), GamepadMapper()]
    private var states: [GamepadState] = [GamepadState(), GamepadState()]
    /// The open controllers, first two by connection order.
    private var pads: [(id: SDL_JoystickID, pad: OpaquePointer)] = []
    private var mappingGeneration = 0

    private init() {
        guard SDLSubsystems.gamepads else { return }
        // SDL's events are pumped from GLib's main loop, often enough for
        // a controller (and cheaply).
        g_timeout_add(8, { _ in
            MainActor.assumeIsolated { Joysticks.shared.poll() }
            return 1
        }, nil)
        updateMapping()
    }

    private func poll() {
        var event = SDL_Event()
        var changed = Set<Int>()
        while SDL_PollEvent(&event) {
            switch SDL_EventType(rawValue: event.type) {
            case SDL_EVENT_GAMEPAD_ADDED:
                if let pad = SDL_OpenGamepad(event.gdevice.which) {
                    pads.append((event.gdevice.which, pad))
                }
                configure()
            case SDL_EVENT_GAMEPAD_REMOVED:
                if let index = pads.firstIndex(where: { $0.id == event.gdevice.which }) {
                    SDL_CloseGamepad(pads[index].pad)
                    pads.remove(at: index)
                }
                configure()
            case SDL_EVENT_GAMEPAD_AXIS_MOTION, SDL_EVENT_GAMEPAD_BUTTON_DOWN, SDL_EVENT_GAMEPAD_BUTTON_UP:
                if let index = pads.prefix(2).firstIndex(where: { $0.id == event.gdevice.which }) {
                    changed.insert(index)
                }
            default:
                break
            }
        }
        for index in changed {
            read(index)
        }
    }

    /// Controllers came or went: the first two drive joysticks 0 and 1.
    private func configure() {
        for index in min(pads.count, 2)..<2 {
            // Gone: let go of its keys.
            states[index] = GamepadState()
            apply(index)
        }
        for index in pads.prefix(2).indices {
            read(index)
        }
    }

    private func read(_ index: Int) {
        let pad = pads[index].pad
        func axis(_ axis: SDL_GamepadAxis) -> Double {
            Double(SDL_GetGamepadAxis(pad, axis)) / 32767
        }
        func held(_ button: SDL_GamepadButton) -> Bool {
            SDL_GetGamepadButton(pad, button)
        }
        // The d-pad takes over from the stick when pressed. (Up is
        // positive, as the Mac's GameController has it; SDL's is down.)
        let dx: Double = held(SDL_GAMEPAD_BUTTON_DPAD_RIGHT) ? 1 : held(SDL_GAMEPAD_BUTTON_DPAD_LEFT) ? -1 : 0
        let dy: Double = held(SDL_GAMEPAD_BUTTON_DPAD_UP) ? 1 : held(SDL_GAMEPAD_BUTTON_DPAD_DOWN) ? -1 : 0
        let x = dx != 0 ? dx : Self.deadZone(axis(SDL_GAMEPAD_AXIS_LEFTX))
        let y = dy != 0 ? dy : -Self.deadZone(axis(SDL_GAMEPAD_AXIS_LEFTY))
        var buttons: Set<GamepadButton> = []
        let all: [(GamepadButton, SDL_GamepadButton)] = [
            (.a, SDL_GAMEPAD_BUTTON_SOUTH), (.b, SDL_GAMEPAD_BUTTON_EAST), (.x, SDL_GAMEPAD_BUTTON_WEST),
            (.y, SDL_GAMEPAD_BUTTON_NORTH), (.leftShoulder, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER),
            (.rightShoulder, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER), (.leftStickButton, SDL_GAMEPAD_BUTTON_LEFT_STICK),
            (.rightStickButton, SDL_GAMEPAD_BUTTON_RIGHT_STICK), (.menu, SDL_GAMEPAD_BUTTON_START),
            (.options, SDL_GAMEPAD_BUTTON_BACK),
        ]
        for (button, sdl) in all where held(sdl) {
            buttons.insert(button)
        }
        if axis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER) > 0.5 { buttons.insert(.leftTrigger) }
        if axis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) > 0.5 { buttons.insert(.rightTrigger) }
        let state = GamepadState(x: x, y: y, buttons: buttons)
        guard state != states[index] else { return }
        states[index] = state
        if index == 0 {
            let held = states[0].held
            if GamepadSettings.shared.held != held {
                GamepadSettings.shared.held = held
            }
        }
        apply(index)
    }

    /// Sticks rest a little off centre.
    private static func deadZone(_ value: Double) -> Double {
        abs(value) < 0.12 ? 0 : value
    }

    private func apply(_ index: Int) {
        send(mappers[index].update(states[index]), index)
    }

    private func send(_ actions: [GamepadMapper.Action], _ index: Int) {
        guard let host = machine?.host else { return }
        for action in actions {
            switch action {
            case .key(let key, let down):
                host.send(.key(key, down: down))
            case .joystick(let x, let y, let fire):
                host.send(.joystick(index, x: x, y: y, fire: fire))
            }
        }
    }

    /// Picks up settings changes, and a change of disc, releasing or
    /// pressing keys for buttons already held.
    private func updateMapping() {
        mappingGeneration += 1
        let generation = mappingGeneration
        withObservationTracking {
            let (mode, keys) = GamepadSettings.shared.mapping(disc: machine?.bootDiscPath)
            for index in mappers.indices {
                mappers[index].mode = mode
                mappers[index].keys = keys
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, generation == self.mappingGeneration else { return }
                self.updateMapping()
            }
        }
        for index in mappers.indices {
            apply(index)
        }
    }
}
