import BeebHost
import GameController
import Observation

/// Connects game controllers to the BBC in the window in front: the first
/// controller is joystick 0 (left stick or d-pad, A to fire), the second is
/// joystick 1, or they press keys, as `GamepadSettings` says for the disc in
/// its drive 0.
@MainActor
final class Joysticks {
    static let shared = Joysticks()

    /// The machine the controllers drive: the last one whose window was
    /// key. Changing it lets go of everything held on the old one.
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

    private var observers: [NSObjectProtocol] = []
    /// By controller.
    private var mappers: [GamepadMapper] = [GamepadMapper(), GamepadMapper()]
    private var states: [GamepadState] = [GamepadState(), GamepadState()]
    /// Counts `updateMapping` calls, so only the latest one's observation
    /// carries on.
    private var mappingGeneration = 0

    private init() {
        GCController.shouldMonitorBackgroundEvents = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configure() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configure() }
        })
        configure()
        updateMapping()
    }

    private func configure() {
        let controllers = GCController.controllers().prefix(2)
        for index in controllers.count..<2 {
            // Gone: let go of its keys.
            states[index] = GamepadState()
            apply(index)
        }
        for (index, controller) in controllers.enumerated() {
            guard let pad = controller.extendedGamepad else { continue }
            // (Called on the main queue.)
            pad.valueChangedHandler = { [weak self] pad, _ in
                MainActor.assumeIsolated { self?.changed(index, pad) }
            }
        }
    }

    private func changed(_ index: Int, _ pad: GCExtendedGamepad) {
        // The d-pad takes over from the stick when pressed.
        let dx = pad.dpad.xAxis.value, dy = pad.dpad.yAxis.value
        let x = dx != 0 ? dx : pad.leftThumbstick.xAxis.value
        let y = dy != 0 ? dy : pad.leftThumbstick.yAxis.value
        var buttons: Set<GamepadButton> = []
        let all: [(GamepadButton, GCControllerButtonInput?)] = [
            (.a, pad.buttonA), (.b, pad.buttonB), (.x, pad.buttonX), (.y, pad.buttonY),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder),
            (.leftTrigger, pad.leftTrigger), (.rightTrigger, pad.rightTrigger),
            (.leftStickButton, pad.leftThumbstickButton), (.rightStickButton, pad.rightThumbstickButton),
            (.menu, pad.buttonMenu), (.options, pad.buttonOptions),
        ]
        for case (let button, let input?) in all where input.isPressed {
            buttons.insert(button)
        }
        states[index] = GamepadState(x: Double(x), y: Double(y), buttons: buttons)
        if index == 0 {
            let held = states[0].held
            if GamepadSettings.shared.held != held {
                GamepadSettings.shared.held = held
            }
        }
        apply(index)
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
