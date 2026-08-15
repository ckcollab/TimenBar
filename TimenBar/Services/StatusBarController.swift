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
    private weak var appModel: AppModel?
    private let actionButton = StatusSegmentButton(frame: .zero)
    private let durationButton = StatusSegmentButton(frame: .zero)
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(appModel: AppModel, container: ModelContainer) {
        self.appModel = appModel
        statusItem = NSStatusBar.system.statusItem(withLength: 112)
        super.init()

        configureStatusItem()
        let panel = MenuBarPanel()
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

        let stack = NSStackView(views: [actionButton, durationButton])
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        containerButton.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: containerButton.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: containerButton.trailingAnchor),
            stack.topAnchor.constraint(equalTo: containerButton.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: containerButton.bottomAnchor, constant: -2),
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
            (appModel.runningTimer != nil || appModel.lastTimerDraft != nil)
        guard canAct else {
            showPanel()
            return
        }
        Task { await appModel.quickToggleTimer() }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func observeModel() {
        withObservationTracking {
            _ = appModel?.statusBarDurationText
            _ = appModel?.runningTimer
            _ = appModel?.lastTimerDraft
            _ = appModel?.authenticationState
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
        let actionColor: NSColor = !isConnected ? .systemGray : (isRunning ? .systemOrange : .systemGreen)

        let image = NSImage(systemSymbolName: isRunning ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        image?.isTemplate = true
        actionButton.image = image
        actionButton.contentTintColor = .white
        actionButton.segmentColor = actionColor
        actionButton.toolTip = !isConnected
            ? "Open TimenBar to connect Timen"
            : (isRunning ? "Stop the current timer" : "Start the most recent timer")
        actionButton.setAccessibilityLabel(isRunning ? "Stop current timer" : "Start current timer")

        durationButton.title = appModel.statusBarDurationText
        durationButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        durationButton.contentTintColor = .labelColor
        durationButton.segmentColor = actionColor.withAlphaComponent(isRunning ? 0.24 : 0.15)
        durationButton.toolTip = "Open TimenBar"
        durationButton.setAccessibilityLabel("Open TimenBar, current duration \(appModel.statusBarDurationText)")

        let attributes: [NSAttributedString.Key: Any] = [.font: durationButton.font as Any]
        let textWidth = ceil((appModel.statusBarDurationText as NSString).size(withAttributes: attributes).width)
        statusItem.length = 20 + 1 + textWidth + 6
    }

    isolated deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
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
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = segmentColor.cgColor
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
