import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

// MARK: - Configuration
// The hotkey that opens/closes the overlay. ⌘+Space is blocked by Spotlight,
// so default to ⇧⌥+Space (shift + option + space). ⌥⌘+Space also works if you
// prefer. To change: modify `hotkeyModifiers` and `hotkeyKeyCode` below.
//
// Common keyCodes: space=49, Q=12, W=13, E=14, R=15, T=16,
//                  Y=17, U=18, I=19, O=21, P=22, `[`=33
let hotkeyModifiers: NSEvent.ModifierFlags = [.shift, .option]
let hotkeyKeyCode: Int = 49                 // space bar
private let carbonHotkeyID = EventHotKeyID(signature: OSType(0x5048544E), id: 1) // PHTN

// MARK: - App entry point
//
// A menu-bar/overlay-style app has no main window, so we drive
// NSApplication manually instead of using SwiftUI's App lifecycle
// (which would exit immediately when there's nothing on screen).

@main
enum OverlayMain {
    static func main() {
        FileHandle.standardError.write("[photon-overlay] boot\n".data(using: .utf8)!)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        FileHandle.standardError.write("[photon-overlay] calling app.run()\n".data(using: .utf8)!)
        app.run()
        FileHandle.standardError.write("[photon-overlay] app.run() RETURNED (this is unexpected)\n".data(using: .utf8)!)
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private let state = ScanState()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var reindexMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write("[photon-overlay] didFinishLaunching\n".data(using: .utf8)!)

        // Global key monitors only fire for trusted (Accessibility-enabled) processes,
        // and trust is evaluated at monitor-install time — so a process launched
        // untrusted can NEVER start receiving events, even after permission is granted.
        // Prompt once; if untrusted, poll for the flip and auto-relaunch.
        let prompt = ["AXTrustedCheckOptionPrompt": true] as NSDictionary
        let trusted = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
        FileHandle.standardError.write("[photon-overlay] Accessibility trusted: \(trusted)\n".data(using: .utf8)!)
        if !trusted { startTrustPoller() }

        let panel = OverlayPanel()
        panel.onClose = { [weak self] in self?.hide() }

        let root = OverlayView(
            state: state,
            onSubmit:     { r in NSWorkspace.shared.open(r.path) },
            onReveal:     { r in NSWorkspace.shared.open(r.containingFolder) },
            onReindex:    { [weak self] in self?.state.scan() },
            onClose:      { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: root)
        self.panel = panel

        registerSystemHotkey()
        installHotkeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        FileHandle.standardError.write("[photon-overlay] terminating\n".data(using: .utf8)!)
    }

    // MARK: Hotkeys

    private func registerSystemHotkey() {
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
            UInt32(shiftKey | optionKey),
            carbonHotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            FileHandle.standardError.write("[photon-overlay] RegisterEventHotKey failed: \(status)\n".data(using: .utf8)!)
        }
    }

    private func installHotkeys() {
        func handlesOverlayToggle(_ event: NSEvent) -> Bool {
            event.keyCode == hotkeyKeyCode
                && event.modifierFlags.contains(.shift)
                && event.modifierFlags.contains(.option)
        }

        // Overlay toggle hotkey (configured via constants above)
        // Use `.contains` so it works even if other modifier flags (capsLock, etc.) are set
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if handlesOverlayToggle(event) {
                DispatchQueue.main.async { self?.toggle() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if handlesOverlayToggle(event) {
                self?.toggle()
                return nil
            }
            return event
        }
        // ⌥+R → reindex  (R keyCode = 15)
        reindexMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.option),
                  event.keyCode == 15 else { return }
            DispatchQueue.main.async { self?.state.scan() }
        }
    }

    // MARK: Show / hide

    private func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    private func show() {
        guard let panel else { return }
        positionCenteredOnMainScreen(panel)
        state.resetQuery()  // just clear query/selection, keep cached results
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if state.results.isEmpty { state.scan() }  // initial scan if needed
    }

    private func hide() {
        panel?.orderOut(nil)
        // Don't wipe results — keep them cached so ⌘+Space next time is instant.
        // Only clear the query text so the overlay re-shows with full unfiltered results.
        state.resetQuery()
    }

    // We keep running with zero visible windows (the panel is hidden until
    // the hotkey fires), so opt out of auto-termination.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Trust polling + auto-relaunch

    private func startTrustPoller() {
        Task { @MainActor in
            while !AXIsProcessTrustedWithOptions(nil) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            FileHandle.standardError.write("[photon-overlay] trust granted — relaunching\n".data(using: .utf8)!)
            relaunch()
        }
    }

    private func relaunch() {
        guard let binaryPath = CommandLine.arguments.first else { return }
        let task = Process()
        task.launchPath = binaryPath
        do {
            try task.run()
            exit(0)               // hand off to the freshly-trusted replacement
        } catch {
            FileHandle.standardError.write("[photon-overlay] relaunch failed: \(error)\n".data(using: .utf8)!)
        }
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

/// Borderless, floating, keyable panel that hides itself when it loses key
/// (i.e. the user clicked outside), matching the spec's dismissal behavior.
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
        // Click outside / focus loss → dismiss.
        onClose?()
    }

    // Escape is handled in SwiftUI via .onKeyPress; this is a backstop.
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
