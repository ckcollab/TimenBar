import AppKit
import Observation
import SwiftData
import SwiftUI

/// Owns one split status item: elapsed time opens the panel, while play/pause
/// performs the timer action without opening it.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let container: ModelContainer
    private weak var appModel: AppModel?
    private var settingsWindowController: NSWindowController?
    private let actionButton = StatusSegmentButton(frame: .zero)
    private let durationButton = StatusSegmentButton(frame: .zero)
    private let durationLabel = StatusDurationLabel(labelWithString: "0:00")
    private let splitBackground = SplitStatusBackgroundView(frame: .zero)
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(appModel: AppModel, container: ModelContainer) {
        self.appModel = appModel
        self.container = container
        statusItem = NSStatusBar.system.statusItem(withLength: 112)
        super.init()

        configureStatusItem()
        let panel = MenuBarPanel(showSettings: { [weak self] in
            self?.showSettings()
        })
            .environment(appModel)
            .modelContainer(container)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.contentSize = NSSize(width: 448, height: 620)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }

        refresh()
        observeModel()
    }

    private func configureStatusItem() {
        guard let containerButton = statusItem.button else { return }
        containerButton.image = nil
        containerButton.title = ""
        containerButton.isBordered = false

        actionButton.target = self
        actionButton.action = #selector(toggleTimer)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.widthAnchor.constraint(equalToConstant: 20).isActive = true

        durationButton.target = self
        durationButton.action = #selector(togglePanel)
        durationButton.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.textColor = .white
        durationLabel.alignment = .center
        durationButton.addSubview(durationLabel)
        NSLayoutConstraint.activate([
            durationLabel.centerXAnchor.constraint(equalTo: durationButton.centerXAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: durationButton.centerYAnchor),
        ])

        let stack = NSStackView(views: [actionButton, durationButton])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        splitBackground.translatesAutoresizingMaskIntoConstraints = false
        containerButton.addSubview(splitBackground)
        containerButton.addSubview(stack)
        NSLayoutConstraint.activate([
            splitBackground.leadingAnchor.constraint(equalTo: containerButton.leadingAnchor, constant: 2),
            splitBackground.trailingAnchor.constraint(equalTo: containerButton.trailingAnchor, constant: -2),
            splitBackground.centerYAnchor.constraint(equalTo: containerButton.centerYAnchor),
            splitBackground.heightAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: containerButton.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: containerButton.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: containerButton.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 22),
            actionButton.heightAnchor.constraint(equalTo: stack.heightAnchor),
            durationButton.heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    @objc private func toggleTimer() {
        guard let appModel else { return }
        let canAct = appModel.authenticationState == .signedIn &&
            appModel.connectivity.isOnline &&
            (appModel.runningTimer != nil || appModel.quickStartEntry != nil)
        guard canAct else {
            showPanel()
            return
        }
        Task { await appModel.quickToggleTimer(source: "status-bar-play-pause") }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showSettings() {
        guard let appModel else { return }
        if settingsWindowController == nil {
            let settings = SettingsView()
                .environment(appModel)
                .modelContainer(container)
            let hostingController = NSHostingController(rootView: settings)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "TimenBar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 620, height: 460))
            window.contentMinSize = NSSize(width: 560, height: 400)
            window.setFrameAutosaveName("TimenBarSettingsWindow")
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }

        popover.performClose(nil)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeModel() {
        withObservationTracking {
            _ = appModel?.statusBarDurationText
            _ = appModel?.runningTimer
            _ = appModel?.quickStartEntry?.id
            _ = appModel?.authenticationState
            _ = appModel?.connectivity.isOnline
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeModel()
            }
        }
    }

    private func refresh() {
        guard let appModel else { return }
        let isRunning = appModel.runningTimer != nil
        let isConnected = appModel.authenticationState == .signedIn
        let actionColor = isRunning
            ? NSColor(srgbRed: 1.0, green: 0.34, blue: 0.0, alpha: 1.0)
            : NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 0.96)
        let durationColor = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.96)

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: isRunning ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        image?.isTemplate = false
        actionButton.image = image
        actionButton.contentTintColor = .white
        actionButton.segmentColor = .clear
        actionButton.toolTip = !isConnected
            ? "Open TimenBar to connect Timen"
            : (!appModel.connectivity.isOnline ? "TimenBar must be online to change timers"
            : (isRunning ? "Stop the current timer" : "Start the most recent timer")
              )
        actionButton.setAccessibilityLabel(isRunning ? "Stop current timer" : "Start current timer")

        let durationFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationButton.title = ""
        durationLabel.stringValue = appModel.statusBarDurationText
        durationLabel.font = durationFont
        durationButton.contentTintColor = .white
        durationButton.segmentColor = .clear
        splitBackground.actionColor = actionColor
        splitBackground.durationColor = durationColor
        durationButton.toolTip = "Open TimenBar"
        durationButton.setAccessibilityLabel("Open TimenBar, current duration \(appModel.statusBarDurationText)")

        let attributes: [NSAttributedString.Key: Any] = [.font: durationFont]
        let textWidth = ceil((appModel.statusBarDurationText as NSString).size(withAttributes: attributes).width)
        statusItem.length = 2 + 20 + textWidth + 6 + 2
    }

    isolated deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private final class StatusDurationLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SplitStatusBackgroundView: NSView {
    var actionColor: NSColor = .clear { didSet { needsDisplay = true } }
    var durationColor: NSColor = .clear { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let outerPath = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        durationColor.setFill()
        outerPath.fill()

        NSGraphicsContext.saveGraphicsState()
        outerPath.addClip()
        actionColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: min(20, bounds.width), height: bounds.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class StatusSegmentButton: NSButton {
    var segmentColor: NSColor = .clear { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        segmentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) {
        alphaValue = 0.82
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
}
