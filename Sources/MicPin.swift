import AppKit
import CoreAudio
import ServiceManagement

// MicPin — pins one audio input device as the macOS default.
//
// macOS has no device-priority preference: whatever was plugged in or paired
// most recently becomes the default input, so connecting a headset silently
// hands the microphone over to it. MicPin listens for CoreAudio default-device
// and device-list changes and puts the pinned device back.
//
// Output selection is never touched.

// MARK: - CoreAudio helpers

private let systemObject = AudioObjectID(kAudioObjectSystemObject)

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?

    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
    }

    guard status == noErr, let value else {
        return nil
    }

    return value as String
}

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum Audio {
    static var defaultInputID: AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)

        return id
    }

    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = id
        let status = AudioObjectSetPropertyData(systemObject, &addr, 0, nil,
                                               UInt32(MemoryLayout<AudioDeviceID>.size), &device)

        return status == noErr
    }

    static func inputDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard hasInputChannels(id) else {
                return nil
            }

            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else {
                return nil
            }

            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid

            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                     alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))

        return list.contains { $0.mNumberChannels > 0 }
    }

    static func addSystemListener(_ selector: AudioObjectPropertySelector,
                                  handler: @escaping () -> Void) {
        var addr = address(selector)
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main) { _, _ in
            handler()
        }
    }
}

// MARK: - Preferences

enum Prefs {
    private static let pinnedUIDKey = "pinnedInputUID"
    private static let pinnedNameKey = "pinnedInputName"
    private static let pausedKey = "paused"

    static var pinnedUID: String? {
        get { UserDefaults.standard.string(forKey: pinnedUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: pinnedUIDKey) }
    }

    // Kept as a fallback: a receiver can come back with a different UID after a
    // firmware update or a different USB port, but the name stays the same.
    static var pinnedName: String? {
        get { UserDefaults.standard.string(forKey: pinnedNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: pinnedNameKey) }
    }

    static var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: pausedKey) }
        set { UserDefaults.standard.set(newValue, forKey: pausedKey) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var lastRestoredFrom: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MicPin")
        statusItem.button?.image?.isTemplate = true

        menu.delegate = self
        statusItem.menu = menu

        Audio.addSystemListener(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            self?.enforce()
        }

        Audio.addSystemListener(kAudioHardwarePropertyDevices) { [weak self] in
            self?.enforceRepeatedly()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        enforceRepeatedly()
        refreshIcon()
    }

    @objc private func handleWake() {
        enforceRepeatedly()
    }

    // MARK: Enforcement

    private var pinnedDevice: AudioDevice? {
        let devices = Audio.inputDevices()

        if let uid = Prefs.pinnedUID, let match = devices.first(where: { $0.uid == uid }) {
            return match
        }

        guard let name = Prefs.pinnedName else {
            return nil
        }

        return devices.first { $0.name == name }
    }

    private func enforce() {
        defer { refreshIcon() }

        guard !Prefs.isPaused else {
            return
        }

        guard let target = pinnedDevice else {
            return
        }

        let current = Audio.defaultInputID

        guard current != target.id else {
            return
        }

        let previousName = Audio.inputDevices().first { $0.id == current }?.name ?? "unknown device"

        guard Audio.setDefaultInput(target.id) else {
            NSLog("MicPin: failed to set default input to \(target.name)")
            return
        }

        lastRestoredFrom = previousName
        NSLog("MicPin: input was \"\(previousName)\", restored \"\(target.name)\"")
    }

    // macOS sometimes assigns the default input a beat after the device-list
    // notification fires, overwriting whatever we just set. Re-check briefly.
    private func enforceRepeatedly() {
        enforce()

        for delay in [0.4, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforce()
            }
        }
    }

    private func refreshIcon() {
        let symbol: String

        if Prefs.isPaused {
            symbol = "mic.slash.fill"
        } else if Prefs.pinnedUID == nil && Prefs.pinnedName == nil {
            symbol = "mic"
        } else if pinnedDevice == nil {
            symbol = "mic.badge.xmark.fill"
        } else {
            symbol = "mic.fill"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MicPin")
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MicPin")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(header(statusLine()))
        menu.addItem(.separator())
        menu.addItem(header("Pinned input device"))

        let devices = Audio.inputDevices()
        let target = pinnedDevice

        for device in devices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(pinDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == target?.uid ? .on : .off
            menu.addItem(item)
        }

        if devices.isEmpty {
            menu.addItem(header("No input devices found"))
        }

        // A pinned device that is currently unplugged still deserves a row, so
        // it can be seen and unpinned.
        if target == nil, let name = Prefs.pinnedName {
            let item = NSMenuItem(title: "\(name) (not connected)",
                                 action: nil,
                                 keyEquivalent: "")
            item.state = .on
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let none = NSMenuItem(title: "Pin nothing", action: #selector(unpin), keyEquivalent: "")
        none.target = self
        none.state = Prefs.pinnedUID == nil && Prefs.pinnedName == nil ? .on : .off
        menu.addItem(none)

        let pause = NSMenuItem(title: "Pause pinning", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = Prefs.isPaused ? .on : .off
        menu.addItem(pause)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let settings = NSMenuItem(title: "Sound Settings…", action: #selector(openSoundSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MicPin", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        if Prefs.isPaused {
            return "Paused — macOS picks the input"
        }

        guard Prefs.pinnedUID != nil || Prefs.pinnedName != nil else {
            return "Nothing pinned"
        }

        guard let target = pinnedDevice else {
            return "\(Prefs.pinnedName ?? "Pinned device") not connected"
        }

        return "Holding \(target.name)"
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )

        return item
    }

    // MARK: Actions

    @objc private func pinDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else {
            return
        }

        Prefs.pinnedUID = uid
        Prefs.pinnedName = Audio.inputDevices().first { $0.uid == uid }?.name
        Prefs.isPaused = false
        enforce()
    }

    @objc private func unpin() {
        Prefs.pinnedUID = nil
        Prefs.pinnedName = nil
        refreshIcon()
    }

    @objc private func togglePause() {
        Prefs.isPaused.toggle()
        enforce()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MicPin: login item toggle failed: \(error.localizedDescription)")

            let alert = NSAlert()
            alert.messageText = "Couldn’t change the login item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--status") {
    let devices = Audio.inputDevices()
    let currentID = Audio.defaultInputID
    let current = devices.first { $0.id == currentID }?.name ?? "unknown"

    let pinned = Prefs.pinnedUID.flatMap { uid in devices.first { $0.uid == uid } }
        ?? Prefs.pinnedName.flatMap { name in devices.first { $0.name == name } }

    print("pinned:         \(Prefs.pinnedName ?? "(nothing)")")
    print("connected:      \(pinned == nil ? "no" : "yes")")
    print("paused:         \(Prefs.isPaused ? "yes" : "no")")
    print("default input:  \(current)")
    print("holding:        \(!Prefs.isPaused && pinned != nil && currentID == pinned?.id ? "yes" : "no")")
    print("running:        \(NSRunningApplication.runningApplications(withBundleIdentifier: "com.chitranu.micpin").isEmpty ? "no" : "yes")")
    print("inputs:")

    for device in devices {
        print("  \(device.id == currentID ? "*" : " ") \(device.name)")
    }

    exit(0)
}

// Lets the login item be scripted from a terminal instead of only via the menu.
if CommandLine.arguments.contains("--register-login-item") {
    do {
        try SMAppService.mainApp.register()
        print("login item status: \(SMAppService.mainApp.status.rawValue) (1 = enabled)")
        exit(0)
    } catch {
        print("login item registration failed: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--unregister-login-item") {
    do {
        try SMAppService.mainApp.unregister()
        print("login item status: \(SMAppService.mainApp.status.rawValue) (0 = not registered)")
        exit(0)
    } catch {
        print("login item removal failed: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
