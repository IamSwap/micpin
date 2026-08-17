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
    let transport: UInt32

    // Transport tells the user more than the name often does — "BlackHole 2ch"
    // and "iPhone 12 mini Microphone" are far easier to tell apart by kind.
    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "wave.3.right"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "square.stack.3d.up"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI:
            return "bolt.horizontal"
        default:
            return "mic"
        }
    }
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

            return AudioDevice(id: id, uid: uid, name: name, transport: transportType(id))
        }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return 0
        }

        return value
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

// MARK: - Menu row views

// A stock NSMenu cannot look like the Sound or Bluetooth panels in Control
// Centre — those are custom panels, not menus. These views get most of the way
// there while keeping NSMenu's keyboard handling, dismissal and accessibility.

private enum Style {
    static let rowHeight: CGFloat = 32
    static let badge: CGFloat = 22
    static let leftInset: CGFloat = 13
    static let gap: CGFloat = 9
    static let rightInset: CGFloat = 20
    static let cornerRadius: CGFloat = 5

    static var font: NSFont { .menuFont(ofSize: 0) }

    /// Control Centre lightens a hovered row with a translucent wash so the
    /// blur behind still shows. Sampling a native panel: background #787878,
    /// hovered #8C8C8C — about +20/255, i.e. white at ~0.14.
    ///
    /// Not `unemphasizedSelectedContentBackgroundColor`: that is the opaque
    /// list-selection grey (rgb 70,70,70 in dark), which paints over the
    /// translucency and reads far darker than the row it highlights.
    static let hover = NSColor(name: "MicPinHover") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.08)
    }

    static func width(for title: String, extra: CGFloat = 0) -> CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        return leftInset + badge + gap + ceil(text) + rightInset + extra
    }
}

/// Draws the rounded selection fill NSMenu would normally draw for us.
///
/// A custom view has to track the mouse itself: NSMenu updates the item's
/// isHighlighted but never asks the view to redraw, so relying on that alone
/// leaves rows that never light up.
private class HighlightingRowView: NSView {
    var isEnabledRow = true
    private var isHovered = false

    // .inVisibleRect keeps the area in sync with bounds by itself. Installing it
    // on move-to-window matters: updateTrackingAreas() is never called for a
    // view whose frame is set manually, which leaves rows that never light up.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard trackingAreas.isEmpty else {
            return
        }

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlightedRow else {
            return
        }

        // Control Centre highlights with a quiet translucent wash, not the
        // accent colour, and leaves the row's own colours alone.
        let inset = NSRect(x: 5, y: 1, width: bounds.width - 10, height: bounds.height - 2)
        Style.hover.setFill()
        NSBezierPath(roundedRect: inset, xRadius: Style.cornerRadius, yRadius: Style.cornerRadius).fill()
    }

    var isHighlightedRow: Bool {
        isEnabledRow && (isHovered || enclosingMenuItem?.isHighlighted == true)
    }

    func drawLabel(_ title: String, x: CGFloat, colour: NSColor, font: NSFont = Style.font) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let y = (bounds.height - size.height) / 2
        (title as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
}

private final class SectionHeaderView: NSView {
    private let title: String

    init(title: String, width: CGFloat) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: Style.leftInset, y: (bounds.height - size.height) / 2 - 1),
                                 withAttributes: attributes)
    }
}

private final class DeviceRowView: HighlightingRowView {
    private let device: AudioDevice
    private let isPinned: Bool
    private let isAvailable: Bool

    init(device: AudioDevice, isPinned: Bool, isAvailable: Bool, width: CGFloat) {
        self.device = device
        self.isPinned = isPinned
        self.isAvailable = isAvailable

        // Must be the menu-wide width, not this row's own text width, or the
        // highlight stops short of the edge and every row is a different size.
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Style.rowHeight))
        isEnabledRow = isAvailable

        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(device.name)
        setAccessibilityValue(isPinned ? "pinned" : "not pinned")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let badgeRect = NSRect(x: Style.leftInset,
                               y: (bounds.height - Style.badge) / 2,
                               width: Style.badge,
                               height: Style.badge)

        // Filled accent badge marks the active device, as the Sound panel does.
        // The hover wash is grey, so these need no inverted variant.
        let badgeColour: NSColor = isPinned ? .controlAccentColor : .quaternaryLabelColor
        let glyphColour: NSColor = isPinned ? .white : .secondaryLabelColor

        badgeColour.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        // paletteColors, not colour.set() — a template image drawn directly
        // ignores the current fill colour and comes out black.
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColour]))

        if let glyph = NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let size = glyph.size
            let origin = NSPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2)
            glyph.draw(in: NSRect(origin: origin, size: size))
        }

        let colour = isAvailable ? NSColor.labelColor : NSColor.disabledControlTextColor
        drawLabel(device.name, x: badgeRect.maxX + Style.gap, colour: colour)
    }

    override func mouseUp(with event: NSEvent) {
        guard isAvailable, let item = enclosingMenuItem, let menu = item.menu else {
            return
        }

        let index = menu.index(of: item)
        menu.cancelTracking()

        // Fire after the menu has torn down, matching normal item behaviour.
        DispatchQueue.main.async {
            menu.performActionForItem(at: index)
        }
    }
}

/// A plain label row, aligned with the section headers rather than at NSMenu's
/// wider default text inset, so the whole menu shares one left edge.
private final class ActionRowView: HighlightingRowView {
    private let title: String
    private let shortcut: String?

    init(title: String, shortcut: String? = nil, width: CGFloat) {
        self.title = title
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Style.rowHeight))

        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawLabel(title, x: Style.leftInset, colour: .labelColor)

        guard let shortcut else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Style.font,
            .foregroundColor: isHighlightedRow ? NSColor.selectedMenuItemTextColor : NSColor.tertiaryLabelColor,
        ]
        let size = (shortcut as NSString).size(withAttributes: attributes)
        (shortcut as NSString).draw(at: NSPoint(x: bounds.width - size.width - Style.rightInset,
                                               y: (bounds.height - size.height) / 2),
                                    withAttributes: attributes)
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else {
            return
        }

        let index = menu.index(of: item)
        menu.cancelTracking()
        DispatchQueue.main.async { menu.performActionForItem(at: index) }
    }
}

/// A row that reads as a switch and, unlike a normal menu item, does not
/// dismiss the menu — so the state change is actually visible.
private final class ToggleRowView: HighlightingRowView {
    // Read on every draw rather than captured once: the master row doubles as
    // the status line, so flipping the switch changes its own text. Rebuilding
    // the menu instead would tear down the very view handling the click.
    private let titleProvider: () -> String
    private var isOn: Bool
    private let emphasised: Bool

    private var title: String { titleProvider() }

    /// Returns the state that actually took effect, so a failed change reverts.
    private let onToggle: (Bool) -> Bool

    private let switchSize = NSSize(width: 36, height: 21)

    init(title: @escaping () -> String, isOn: Bool, width: CGFloat, emphasised: Bool = false,
         onToggle: @escaping (Bool) -> Bool) {
        self.titleProvider = title
        self.isOn = isOn
        self.emphasised = emphasised
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Style.rowHeight))

        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title())
    }

    /// Return and Space arrive as the menu item's action, not as a mouse event,
    /// so keyboard users need this path — without it the switches are
    /// mouse-only.
    func activate() {
        performToggle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let font = emphasised
            ? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : Style.font
        drawLabel(title, x: Style.leftInset, colour: .labelColor, font: font)

        let track = NSRect(x: bounds.width - switchSize.width - Style.rightInset + 6,
                           y: (bounds.height - switchSize.height) / 2,
                           width: switchSize.width,
                           height: switchSize.height)

        (isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()

        let knob = CGFloat(17)
        let knobRect = NSRect(x: isOn ? track.maxX - knob - 2 : track.minX + 2,
                              y: track.midY - knob / 2,
                              width: knob,
                              height: knob)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    override func mouseUp(with event: NSEvent) {
        performToggle()
    }

    private func performToggle() {
        isOn = onToggle(!isOn)
        needsDisplay = true

        // Deliberately no cancelTracking(): a toggle should show its new state.
        enclosingMenuItem?.menu?.items.forEach { $0.view?.needsDisplay = true }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

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

        let devices = Audio.inputDevices()
        let target = pinnedDevice

        // Widest row decides the menu width, so every custom view agrees.
        let widest = ([statusLine()] + devices.map(\.name)).reduce(CGFloat(210)) {
            max($0, Style.width(for: $1, extra: 46))
        }

        // One switch for the whole app, on the status row. "Pin nothing" and
        // "Pause pinning" used to sit at the bottom doing near-identical
        // things — both stopped the mic being held, differing only in whether
        // the choice was remembered, which is a distinction nobody wants to
        // think about.
        menu.addItem(toggleRow({ [weak self] in self?.statusLine() ?? "" },
                               isOn: !Prefs.isPaused, width: widest,
                               emphasised: true) { [weak self] isOn in
            Prefs.isPaused = !isOn
            self?.enforce()
            return isOn
        })

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Input device", width: widest))

        for device in devices {
            menu.addItem(deviceRow(device, isPinned: device.uid == target?.uid, isAvailable: true,
                                   width: widest))
        }

        if devices.isEmpty {
            menu.addItem(sectionHeader("No input devices found", width: widest))
        }

        // An unplugged choice still gets a row, so it is visible rather than
        // silently missing from the list.
        if target == nil, let name = Prefs.pinnedName {
            let absent = AudioDevice(id: 0, uid: Prefs.pinnedUID ?? name,
                                     name: "\(name) (not connected)", transport: 0)
            menu.addItem(deviceRow(absent, isPinned: true, isAvailable: false, width: widest))
        }

        menu.addItem(.separator())
        menu.addItem(toggleRow({ "Open at login" },
                               isOn: SMAppService.mainApp.status == .enabled,
                               width: widest) { [weak self] isOn in
            self?.setLoginItem(enabled: isOn) ?? false
        })
        menu.addItem(actionRow("Sound Settings…", action: #selector(openSoundSettings), width: widest))

        menu.addItem(.separator())
        menu.addItem(actionRow("Quit MicPin", action: #selector(quit), width: widest,
                               keyEquivalent: "q", shortcut: "⌘Q"))
    }

    private func statusLine() -> String {
        if Prefs.isPaused {
            return "MicPin is off"
        }

        guard Prefs.pinnedUID != nil || Prefs.pinnedName != nil else {
            return "Choose a microphone"
        }

        guard let target = pinnedDevice else {
            return "\(Prefs.pinnedName ?? "Your microphone") is unplugged"
        }

        return "Holding \(target.name)"
    }

    private func sectionHeader(_ title: String, width: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = SectionHeaderView(title: title, width: width)

        return item
    }

    private func deviceRow(_ device: AudioDevice, isPinned: Bool, isAvailable: Bool,
                           width: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: device.name, action: #selector(pinDevice(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device.uid
        item.isEnabled = isAvailable
        item.view = DeviceRowView(device: device, isPinned: isPinned, isAvailable: isAvailable,
                                  width: width)

        return item
    }

    private func actionRow(_ title: String, action: Selector, width: CGFloat,
                           keyEquivalent: String = "", shortcut: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.view = ActionRowView(title: title, shortcut: shortcut, width: width)

        return item
    }

    private func toggleRow(_ title: @escaping () -> String, isOn: Bool, width: CGFloat,
                           emphasised: Bool = false,
                           onToggle: @escaping (Bool) -> Bool) -> NSMenuItem {
        // The action exists for Return and Space; a mouse click is handled by
        // the view itself and never routed here, so it cannot double-fire.
        let item = NSMenuItem(title: title(), action: #selector(activateToggle(_:)), keyEquivalent: "")
        item.target = self
        item.view = ToggleRowView(title: title, isOn: isOn, width: width,
                                  emphasised: emphasised, onToggle: onToggle)

        return item
    }

    @objc private func activateToggle(_ sender: NSMenuItem) {
        (sender.view as? ToggleRowView)?.activate()
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

    @objc private func togglePause() {
        Prefs.isPaused.toggle()
        enforce()
    }

    /// Returns the state that actually took effect, so the switch can revert.
    private func setLoginItem(enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            return enabled
        } catch {
            NSLog("MicPin: login item toggle failed: \(error.localizedDescription)")

            // The menu is still open; an alert cannot be shown over menu
            // tracking, so dismiss first and report afterwards.
            menu.cancelTracking()

            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn’t change the login item"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }

            return !enabled
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
