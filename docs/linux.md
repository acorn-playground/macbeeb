# MacBeeb on Linux

MacBeeb builds on Linux from the same package as on the Mac: the same
emulation, the same app logic, and a GNOME user interface (GTK 4 and
libadwaita) in place of SwiftUI and AppKit. It's developed on Ubuntu 26.04
(GTK 4.22, libadwaita 1.9, SDL 3.4, GStreamer 1.28, Swift 6.4).

```
scripts/linux-deps.sh          # the packages to build against (Ubuntu/Debian)
swift build --product MacBeeb  # the app
.build/debug/MacBeeb
make test                      # the test suite, as on the Mac
scripts/install-linux.sh       # builds it optimised and installs it in ~/.local (--prefix, --uninstall)
```

The installed app lives in `PREFIX/lib/macbeeb` (with the MCP server, the
`beeb` tool, BeebAsm, Baron and the guides), linked from `PREFIX/bin`, with
its desktop entry, icon (drawn by `Tools/icon/linux.py`), file types and
AppStream details in `PREFIX/share`. `.github/workflows/linux.yml` builds
and tests on Ubuntu 26.04.

## How the code divides

| Path | What | Built for |
| --- | --- | --- |
| `Sources/Beeb*` | The emulation, ROMs, capture, printing, networks, agents, DAP | Both |
| `Sources/MacBeeb/Shared` | The app's logic: machines, networks, the library, the debugger's model, settings | Both |
| `Sources/MacBeeb/macOS` | The Mac app's interface (SwiftUI, AppKit, Metal, Sparkle) | macOS |
| `Sources/MacBeeb/Linux` | The Linux app's interface (GTK, libadwaita, OpenGL, SDL) | Linux |
| `Sources/CGtk`, `CSDL3`, `CGStreamer`, `CCairo`, `CZlib` | The system libraries, through pkg-config | Linux |

`Package.swift` picks the folders by the platform it's built on. Both apps
are the `MacBeeb` executable.

### What differs, and where

The libraries are portable, with platform code behind `#if` where an Apple
framework has no Linux equivalent in Foundation:

- Screenshots: ImageIO on the Mac, a zlib PNG encoder on Linux
  (`BeebCapture/PNGEncoder.swift`).
- Recordings: AVFoundation on the Mac, GStreamer on Linux
  (`BeebCapture/VideoRecorder+GStreamer.swift`): H.264 and HEVC in MP4, and
  ProRes in QuickTime, as on the Mac.
- Printouts: Core Graphics on the Mac, Cairo on Linux
  (`BeebPrint/Printout+Cairo.swift`), laid out identically.
- Fingerprints: CryptoKit on the Mac, the same API in BeebCore elsewhere
  (`BeebCore/Portability/Digests.swift`).
- Sockets: Network.framework for the debug adapter on the Mac, POSIX on
  Linux; the agent socket is in `$XDG_RUNTIME_DIR/MacBeeb` on Linux.
- Room credentials: the Keychain on the Mac, the Secret Service (GNOME
  Keyring) on Linux, falling back to a file only the user can read.
- Save states: LZFSE, from the Compression framework on the Mac and Apple's
  reference implementation on Linux (`Sources/CLZFSE`, vendored), so a
  `.beebstate` file is the same on both; the Master 512's RAM in a snapshot
  is LZ4 in Apple's container, by BeebCore's own encoder on Linux.
- BeebCore uses full Foundation on the Mac and Linux, FoundationEssentials
  only on WebAssembly (`#if os(WASI)`).

MacBeeb's files are in `~/.local/share/MacBeeb` on Linux (the XDG data
directory), where the Mac has `~/Library/Application Support/MacBeeb`.

### The shared app, and `Platform`

The shared code asks the platform for what only it can do through
`Platform` (`Shared/PlatformRequests.swift` lists it): choosing files,
alerts and confirmations, the clipboard, recent documents, opening and
revealing files, the Trash, pictures (`PlatformImage`: a `CGImage` on the
Mac, a GDK texture on Linux), and where room credentials go. The Mac's
(`macOS/Platform.swift`) runs its panels modally, so completions are called
before they return, exactly as the AppKit code always did; Linux's are
asynchronous.

Types the shared code names but each platform provides (with the same
names on both): `Renderer`, `AudioOutput`, `Joysticks`, `NewDiscPanel`,
`NetworkStudioCommands`, `NetworkSelfTest`, `DocumentationCapture`, and
the machine's `runSelfTestIfRequested()`.

`MainTimer` is the shared repeating timer: Foundation's `Timer` on the Mac;
on Linux, where GLib's main loop runs rather than Foundation's run loop, a
dispatch timer on the main queue.

## The Linux app

### Its parts

- `Linux/App.swift`: the GNOME application (`com.accidentalfish.MacBeeb`,
  one instance; files opened again go to it), its actions and shortcuts.
- `Linux/GTK/`: a thin Swift layer over GTK and libadwaita (below).
- `Linux/Machine/`: the machine window (`MachineWindow`), the emulator's
  picture (`EmulatorArea`, `Renderer`: the Mac's Metal shader in GLSL),
  keys (`LinuxKeyMap`), sound and game controllers (SDL).
- `Linux/Windows/`: the other windows.

### Keyboard

In a machine window the keyboard is the BBC's, by position as on the Mac:
`LinuxKeyMap` turns PC keys into the Mac's key codes, so the shared
`KeyboardTranslator`, the BBC layout and custom mappings (and their saved
settings) are the Mac's. Control is the BBC's CTRL, so the app's own
shortcuts use **Alt** where the Mac uses Command (the BBC has neither):
Alt+O opens a disc, Alt+P pauses, and so on (Help > Keyboard Shortcuts).
Right Alt is the BBC's SHIFT LOCK, as the Mac's Option is. Windows that
aren't machines also take GNOME's usual Control shortcuts.

### The GTK layer

Widgets are thin Swift wrappers. GTK owns widgets (a window its tree, a
parent its children); a wrapper just points at one and is cheap to make
and drop. Layout reads like SwiftUI's:

```swift
Box(.vertical, spacing: 12) {
    Label("Model B", style: "title-2")
    Button("Play") { machine.play() }.style("suggested-action", "pill")
}
.margin(24)
```

- `track { … }` runs a closure now and again whenever the `@Observable`
  state it reads changes, for as long as the widget lives: the way state
  reaches widgets.
- Closures attached to a widget may hold wrappers of widgets in the same
  window strongly (there's no cycle: wrappers don't own widgets). A Swift
  object that has to live as long as a window is kept with
  `window.keep(object)`.
- `Windows.show(key) { … }` opens a window once, bringing it forward if
  it's open (SwiftUI's `openWindow(id:)`).
- Menus are `Menu { … }` models of `MenuItem`s naming actions
  (`"win.name"`, `"app.name"`); `Action`s are commands, toggles (a check
  in a menu) or choices (radio items).
- Prefer libadwaita's pieces, as GNOME's own apps do: `ToolbarView` and
  `HeaderBar`, `PreferencesPage`/`PreferencesGroup` and their rows,
  `StatusPage`, `ToastOverlay`, `AlertDialog`, `Dialog`, `ViewStack`,
  `NavigationSplitView`, `Table` (GtkColumnView) for tables.
- C functions GTK has as macros or variadics are in `Sources/CGtk/shim.h`.
  `cast(_:)` converts between GTK's pointer types, whichever way a C
  function wants.

### Testing it where no one sees

`scripts/linux-headless.sh` runs a private, headless GNOME Shell. The
app's self-tests then run as on the Mac, and save what they show:

```
scripts/linux-headless.sh macbeeb-test &
eval "$(scripts/linux-headless.sh --env macbeeb-test)"
.build/debug/MacBeeb -MacBeebSelfTest /tmp/out.png                 # PRINT 6*7: the frame, the display, the window
.build/debug/MacBeeb -MacBeebSelfTest /tmp/out.png -MacBeebSelfTestDisplay crt
.build/debug/MacBeeb -MacBeebSelfTest /tmp/out.png -MacBeebSelfTestOpen app.library   # any action; every window captured
```

`-MacBeebSelfTestWait seconds` waits before capturing,
`-MacBeebSelfTestMenu` captures the machine window's menu open, and
`-MacBeebSelfTestIdle` leaves the app running afterwards.

A debug build emulates at about half the BBC's speed, which is enough for
the self-tests but loses keys typed quickly; build with `-c release` (as
the installer does) to play.

## What's different from the Mac

- **Updates.** There's no Sparkle: Help > Check for Updates asks GitHub
  for the latest release and says how to update from the source.
- **Quick Look.** Linux has no equivalent, so there's no previewer for
  discs and tapes in the file manager (they show MacBeeb's file types and
  open in it).
- **Capturing the mouse.** Wayland doesn't let an app lock the pointer
  without a protocol GTK doesn't expose, so a captured mouse (for an AMX
  mouse or a joystick on the mouse) follows the pointer over the picture
  rather than being held at its centre. Alt+M captures and releases it
  (Control-Command-M on the Mac), and so does Alt+Escape.
- **Developer tools.** The Mac's network self-test and its documentation
  capture (which draw the guides' pictures) are Mac-only; on Linux their
  flags are ignored, and Linux has its own self-tests (above).
