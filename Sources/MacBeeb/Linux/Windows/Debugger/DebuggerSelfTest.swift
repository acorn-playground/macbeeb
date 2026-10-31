import BeebCore
import BeebHost
import CGtk
import Foundation

/// The debugger's self-tests, as the Mac's (MachineController+Mac.swift),
/// run when the window opens with `-MacBeebSelfTestDebugger SCENARIO`
/// beside `-MacBeebSelfTest path.png -MacBeebSelfTestOpen win.debugger`;
/// each saves the window at its stages as path-SUFFIX.png:
///
/// - `stop`: stopped at OSWRCH as a key's echoed, tracing (-debugger).
/// - `basic`: a program stopped at a BASIC breakpoint in a PROC
///   (-basic), stepped (-basic-step), then stopped at an error
///   (-basic-error).
/// - `profile`: a busy BASIC loop, profiled, with the Profile tab showing
///   (-profile).
/// - `memory`: stopped, then stepped out of OSWRCH, the character it
///   wrote changed since the last stop (-memory),
///   one being edited (-memory-edit).
/// - `basic-empty`: the BASIC view with no program (-basic-empty).
/// - `editors`: the BASIC program stopped, with the listing's context menu
///   (-context), a line's breakpoint editor (-breakpoint) and a variable's
///   editor (-variable).
/// - `log`: a log point's output, in the Log tab (-log).
/// - `second`: a 6502 second processor fitted, stopped, showing its CPU
///   (-second). (It's remembered, as choosing one in the menu is: run it
///   with its own settings.)
@MainActor
enum DebuggerSelfTest {
    private static var ran = false

    static func start(_ controller: DebuggerController) {
        let defaults = UserDefaults.standard
        guard !ran, let scenario = defaults.string(forKey: "MacBeebSelfTestDebugger"),
              let path = defaults.string(forKey: "MacBeebSelfTest") else { return }
        ran = true
        // (-MacBeebSelfTestDebuggerWidth: the window at that width.)
        let width = defaults.integer(forKey: "MacBeebSelfTestDebuggerWidth")
        if width > 0 { controller.window.setDefaultSize(width: Int32(width), height: 640) }
        let debugger = controller.model
        let host = controller.machine.host
        /// The window (and a popover, which is a surface of its own: a menu's
        /// is drawn as it is; an editor's, which isn't drawn here, from its
        /// contents moved to a window).
        func capture(_ suffix: String, popover: Widget? = nil) async {
            Capture.write(controller.window, to: path.replacingOccurrences(of: ".png", with: "-\(suffix).png"))
            guard let popover, let child = gtk_popover_get_child(cast(popover.widget)) else { return }
            let file = path.replacingOccurrences(of: ".png", with: "-\(suffix)-popover.png")
            if let contents = gtk_widget_get_parent(child), Capture.png(of: Widget(contents)) != nil {
                Capture.write(Widget(contents), to: file)
                return
            }
            g_object_ref(gpointer(child))
            gtk_popover_set_child(cast(popover.widget), nil)
            let window = Window(title: "Popover", width: -1, height: -1)
            window.content = Widget(child)
            g_object_unref(gpointer(child))
            window.present()
            try? await Task.sleep(for: .seconds(0.5))
            Capture.write(window, to: file)
            window.destroy()
        }
        Task { @MainActor in
            switch scenario {
            case "stop":
                debugger.addBreakpoint(Breakpoint(start: 0xFFEE))
                debugger.setTracing(true)
                try? await Task.sleep(for: .milliseconds(300))
                host.send(.type("P"))
                try? await Task.sleep(for: .seconds(2))
                await capture("debugger")
            case "memory":
                debugger.view.memoryAddress = 0x7D00
                debugger.addBreakpoint(Breakpoint(start: 0xFFEE))
                try? await Task.sleep(for: .milliseconds(300))
                host.send(.type("P"))
                try? await Task.sleep(for: .seconds(1.5))
                // (Out of OSWRCH: the character's on the screen.)
                debugger.run(.stepOut)
                try? await Task.sleep(for: .seconds(1.5))
                await capture("memory")
                controller.memory.testEdit(0x41)
                try? await Task.sleep(for: .seconds(0.5))
                await capture("memory-edit", popover: controller.memory.testPopover)
            case "log":
                debugger.addBreakpoint(Breakpoint(start: 0xFFEE, logMessage: "OSWRCH A={A} X={X}"))
                try? await Task.sleep(for: .milliseconds(300))
                host.send(.type("PRINT \"LOG\"\n"))
                try? await Task.sleep(for: .seconds(2))
                await capture("log")
            case "second":
                controller.machine.setCoprocessor(.mos6502)
                try? await Task.sleep(for: .seconds(3))
                debugger.view.cpu = .parasite
                debugger.pauseOrContinue()
                try? await Task.sleep(for: .seconds(1.5))
                await capture("second")
            case "profile":
                host.send(.type("MODE 2\nREPEAT:GCOL0,RND(7):DRAW RND(1280),RND(1024):UNTIL FALSE\n"))
                try? await Task.sleep(for: .seconds(3))
                debugger.setProfiling(true)
                try? await Task.sleep(for: .seconds(2))
                debugger.setProfiling(false)
                try? await Task.sleep(for: .seconds(0.5))
                await capture("profile")
            case "basic":
                await basicProgram(debugger, host)
                try? await Task.sleep(for: .seconds(2))
                await capture("basic")
                debugger.basicStep(.into)
                try? await Task.sleep(for: .seconds(1))
                await capture("basic-step")
                debugger.removeAllBasicBreakpoints()
                debugger.basicPauseOrContinue()
                try? await Task.sleep(for: .seconds(2))
                await capture("basic-error")
            case "basic-empty":
                debugger.view.basic = true
                try? await Task.sleep(for: .seconds(1.5))
                await capture("basic-empty")
            case "editors":
                await basicProgram(debugger, host)
                try? await Task.sleep(for: .seconds(2))
                controller.listing.testContextMenu(line: 130)
                try? await Task.sleep(for: .seconds(0.5))
                await capture("context", popover: controller.listing.testPopovers[0])
                controller.listing.testEdit(line: 130)
                try? await Task.sleep(for: .seconds(0.5))
                await capture("breakpoint", popover: controller.listing.testPopovers[1])
                controller.listing.dismissPopovers()
                controller.variables.testEdit()
                try? await Task.sleep(for: .seconds(0.5))
                await capture("variable", popover: controller.variables.testPopover)
            default:
                break
            }
        }
    }

    /// A program with a PROC, stopped at a BASIC breakpoint in it (N%=2),
    /// watched, then RUN.
    private static func basicProgram(_ debugger: DebuggerModel, _ host: EmulatorHost) async {
        host.send(.paste("""
        10 total=0:DIM grid%(2,2)
        20 FOR I%=1 TO 3
        30 PROCadd(I%)
        40 NEXT
        50 PRINT total/0
        60 END
        100 DEF PROCadd(N%)
        110 LOCAL T,name$
        120 T=N%*2:name$="Step "+STR$N%
        130 total=total+T:grid%(N%-1,1)=T
        140 ENDPROC

        """))
        try? await Task.sleep(for: .seconds(1))
        debugger.addBasicBreakpoint(BasicBreakpoint(line: 130, condition: "N%=2"))
        debugger.setBasicErrorStop(.untrapped)
        debugger.addBasicWatch("total*10")
        debugger.addBasicWatch("grid%(0,1)")
        debugger.toggleBasicArray("grid%(")
        // (The commands run on the emulation thread.)
        try? await Task.sleep(for: .seconds(0.5))
        host.send(.paste("RUN\n"))
    }
}
