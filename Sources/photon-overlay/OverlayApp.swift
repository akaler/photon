import AppKit
import Carbon.HIToolbox
import SwiftUI
import PhotonCore

// MARK: - Configuration
// ⌥+Space toggles the overlay. To change the key, edit `hotkeyKeyCode` and
// the modifier flags passed to RegisterEventHotKey below.
// Common keyCodes: space=49, Q=12, W=13, E=14, R=15, T=16, Y=17, U=18, I=19,
//                  O=21, P=22, `[`=33
let hotkeyKeyCode: Int = 49                 // space bar
private let carbonHotkeyID = EventHotKeyID(signature: OSType(0x5048544E), id: 1) // PHTN

// MARK: - App entry point
@main
enum OverlayMain {
    static func main() {
        FileHandle.standardError.write("[photon-overlay] boot\n".data(using: .utf8)!)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private let state = ScanState()
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write("[photon-overlay] didFinishLaunching\n".data(using: .utf8)!)

        // Re-register the hotkey when the user flips the trigger in Settings.
        NotificationCenter.default.addObserver(
            forName: ScanState.hotkeyChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reregisterHotkey() }
        }

        let panel = OverlayPanel()
        panel.onClose = { [weak self] in self?.hide() }

        let root = OverlayView(
            state: state,
            onSubmit:  { r in
                if r.kind == .calculator {
                    if let value = r.copyValue {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    self.hide()
                } else {
                    NSWorkspace.shared.open(r.path)
                    // Record the launch so the home screen and search ranking
                    // can favor items the user actually uses.
                    self.state.recordLaunch(path: r.path.path)
                }
            },
            onReveal:  { r in
                guard r.kind != .calculator else { return } // nothing to reveal
                NSWorkspace.shared.open(r.containingFolder)
            },
            onClose:   { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: root)
        self.panel = panel

        registerHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    // MARK: Hotkey (system-level Carbon hotkey — no Accessibility permission needed)

    private func registerHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard status == noErr,
                      hotkeyID.signature == carbonHotkeyID.signature,
                      hotkeyID.id == carbonHotkeyID.id else {
                    return noErr
                }

                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in delegate.toggle() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            nil
        )

        let status = RegisterEventHotKey(
            UInt32(hotkeyKeyCode),
            Config.load().usesCommandSpace ? UInt32(cmdKey) : UInt32(optionKey),
            carbonHotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            FileHandle.standardError.write("[photon-overlay] RegisterEventHotKey failed: \(status)\n".data(using: .utf8)!)
        } else {
            let label = Config.load().usesCommandSpace ? "⌘+Space" : "⌥+Space"
            FileHandle.standardError.write("[photon-overlay] hotkey registered (\(label))\n".data(using: .utf8)!)
        }
    }

    /// Re-register the hotkey after the user flips the trigger in Settings.
    private func reregisterHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registerHotkey()
    }

    // MARK: Show / hide

    private func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    private func show() {
        guard let panel else { return }
        positionCenteredOnMainScreen(panel)
        state.resetQuery()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Must fire AFTER the panel is key, or the view's focus assertion
        // lands on a non-key window and is dropped.
        state.notifyReopen()
        if state.results.isEmpty { state.scan() }
    }

    private func hide() {
        panel?.orderOut(nil)
        state.resetQuery()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func positionCenteredOnMainScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - OverlayPanel

final class OverlayPanel: NSPanel {
    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = false
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.hidesOnDeactivate = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
