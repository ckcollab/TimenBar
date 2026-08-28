import AppKit
import Observation
import SwiftData
import SwiftUI

/// Owns one split status item: elapsed time opens the panel, while play/pause
/// performs the timer action without opening it.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let container: ModelContainer
    private weak var appModel: AppModel?
    private var settingsWindowController: NSWindowController?
    private var composerWindowController: NSWindowController?
    private var displayedComposerID: String?
    private var displayedComposerAttachment: ComposerAttachmentSide?
    private var composerAnchorScreenPoint: CGPoint?
    private var composerAnchorTarget: ComposerAnchorTarget?
    private let composerAttachmentLayout = ComposerAttachmentLayout()
    private var isForcingPopoverClose = false
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
        }, presentNewTimer: { [weak self] point in
            self?.presentNewTimer(at: point)
        }, presentEntryComposer: { [weak self] entry, point in
            self?.presentComposer(for: entry, at: point)
        })
            .environment(appModel)
            .modelContainer(container)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.contentSize = NSSize(width: 448, height: 620)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopoverIfAllowed() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopoverIfAllowed() }
        }

        refresh()
        observeModel()
        observeComposerPresentation()
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
        if hasBlockingPopoverPresentation {
            restorePopoverPresentation()
        } else if popover.isShown {
            closePanelPairPreservingComposer()
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

    func popoverShouldClose(_: NSPopover) -> Bool {
        isForcingPopoverClose ||
            (!hasBlockingPopoverPresentation && appModel?.composerMode == nil)
    }

    func popoverDidShow(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        synchronizeComposerWindow(activate: false)
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        composerWindowController?.window?.orderOut(nil)
    }

    private var hasBlockingPopoverPresentation: Bool {
        appModel?.idlePrompt != nil ||
            appModel?.errorMessage != nil ||
            popover.contentViewController?.view.window?.attachedSheet != nil
    }

    private func closePopoverIfAllowed() {
        guard !hasBlockingPopoverPresentation else { return }
        if appModel?.composerMode != nil {
            closePanelPairPreservingComposer()
        } else {
            popover.performClose(nil)
        }
    }

    private func closePanelPairPreservingComposer() {
        composerWindowController?.window?.orderOut(nil)
        isForcingPopoverClose = true
        popover.performClose(nil)
        isForcingPopoverClose = false
    }

    private func restorePopoverPresentation() {
        if !popover.isShown { showPanel() }
        NSApp.activate(ignoringOtherApps: true)
        let window = popover.contentViewController?.view.window
        window?.makeKeyAndOrderFront(nil)
        window?.attachedSheet?.makeKeyAndOrderFront(nil)
        synchronizeComposerWindow(activate: true)
    }

    private func showSettings() {
        guard let appModel else { return }
        guard !hasBlockingPopoverPresentation else {
            restorePopoverPresentation()
            return
        }
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

        closePanelPairPreservingComposer()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentNewTimer(at screenPoint: CGPoint) {
        composerAnchorScreenPoint = screenPoint
        composerAnchorTarget = .newTimerButton
        appModel?.presentNewTimer()
    }

    private func presentComposer(for entry: TimeEntry, at screenPoint: CGPoint) {
        composerAnchorScreenPoint = screenPoint
        composerAnchorTarget = .entryRow
        if appModel?.isRunningEntry(entry) == true {
            appModel?.presentRunningTimer()
        } else {
            appModel?.presentEdit(entry)
        }
    }

    private func synchronizeComposerWindow(activate: Bool = true) {
        guard let appModel, let mode = appModel.composerMode else {
            destroyComposerWindow()
            return
        }

        popover.behavior = .applicationDefined
        if !popover.isShown { showPanel() }
        guard let parentWindow = popover.contentViewController?.view.window else { return }
        let attachment = ComposerAttachmentSide.trailing

        if displayedComposerID != mode.id ||
            displayedComposerAttachment != attachment ||
            composerWindowController == nil
        {
            let composer = AttachedTimerComposerView(
                mode: mode,
                attachment: attachment,
                layout: composerAttachmentLayout
            )
                .environment(appModel)
                .modelContainer(container)
            let hostingController = NSHostingController(rootView: composer)
            // The panel is measured explicitly below. Asking NSHostingController to
            // continuously synchronize preferredContentSize while the SwiftUI view
            // has a fixed width can recursively invalidate AppKit constraints and
            // eventually raise NSGenericException.
            hostingController.sizingOptions = []
            let contentSize = ComposerAttachmentMetrics.contentSize

            if let window = composerWindowController?.window {
                window.parent?.removeChildWindow(window)
                window.contentViewController = hostingController
                window.setContentSize(contentSize)
            } else {
                let panel = ComposerAttachmentPanel(
                    contentRect: NSRect(origin: .zero, size: contentSize),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                panel.contentViewController = hostingController
                // Assigning the hosting controller can reset a borderless panel to
                // its as-yet-unlaid-out preferred size. Restore the measured size
                // before computing the attachment origin so the chevron is not
                // displaced by the full composer width.
                panel.setContentSize(contentSize)
                panel.title = composerWindowTitle(for: mode)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? .none
                    : .utilityWindow
                panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                panel.delegate = self
                composerWindowController = NSWindowController(window: panel)
            }

            displayedComposerID = mode.id
            displayedComposerAttachment = attachment
        }

        guard let composerWindow = composerWindowController?.window else { return }
        if composerWindow.parent !== parentWindow {
            composerWindow.parent?.removeChildWindow(composerWindow)
            parentWindow.addChildWindow(composerWindow, ordered: .above)
        }
        composerWindow.level = parentWindow.level
        positionComposerWindow(
            composerWindow,
            relativeTo: parentWindow,
            attachment: attachment
        )
        composerWindow.orderFront(nil)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            composerWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func positionComposerWindow(
        _ window: NSWindow,
        relativeTo parentWindow: NSWindow,
        attachment: ComposerAttachmentSide
    ) {
        let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parentWindow.frame
        let size = window.frame.size
        let contentFrame: NSRect
        if let contentView = popover.contentViewController?.view {
            let contentFrameInWindow = contentView.convert(contentView.bounds, to: nil)
            contentFrame = parentWindow.convertToScreen(contentFrameInWindow)
        } else {
            contentFrame = parentWindow.frame
        }
        let targetX = contentFrame.minX + (composerAnchorTarget == .newTimerButton ? 16 : 0)
        let x = targetX - size.width + ComposerAttachmentMetrics.windowOverlap
        let anchorY = composerAnchorTarget == .newTimerButton
            ? contentFrame.minY + ComposerAttachmentMetrics.mainFooterHeight / 2
            : (composerAnchorScreenPoint?.y ?? parentWindow.frame.midY)
        let idealY = anchorY - size.height / 2
        let minimumY = visibleFrame.minY + ComposerAttachmentMetrics.screenMargin
        let maximumY = max(minimumY, visibleFrame.maxY - size.height - ComposerAttachmentMetrics.screenMargin)
        let originY = min(maximumY, max(minimumY, idealY))
        window.setFrameOrigin(NSPoint(x: x, y: originY))

        let tailYFromTop = size.height - (anchorY - originY)
        let minimumTailY = ComposerAttachmentMetrics.cornerRadius + ComposerAttachmentMetrics.tailHalfHeight
        let maximumTailY = size.height - minimumTailY
        composerAttachmentLayout.tailY = min(maximumTailY, max(minimumTailY, tailYFromTop))
    }

    private func destroyComposerWindow() {
        displayedComposerID = nil
        displayedComposerAttachment = nil
        composerAnchorScreenPoint = nil
        composerAnchorTarget = nil
        popover.behavior = .transient
        guard let window = composerWindowController?.window else {
            composerWindowController = nil
            return
        }
        window.parent?.removeChildWindow(window)
        window.delegate = nil
        window.close()
        composerWindowController = nil
    }

    private func composerWindowTitle(for mode: TimerComposerMode) -> String {
        switch mode {
        case .new: "New Timer"
        case .running: "Running Timer"
        case .restart: "Restart Entry"
        case .edit: "Edit Time Entry"
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let composerWindow = composerWindowController?.window,
              notification.object as? NSWindow === composerWindow
        else { return }
        displayedComposerID = nil
        displayedComposerAttachment = nil
        composerWindowController = nil
        appModel?.dismissComposer()
    }

    private func observeModel() {
        withObservationTracking {
            _ = appModel?.statusBarDurationText
            _ = appModel?.runningTimer
            _ = appModel?.quickStartEntry?.id
            _ = appModel?.authenticationState
            _ = appModel?.connectivity.isOnline
            _ = appModel?.timenTheme
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeModel()
            }
        }
    }

    private func observeComposerPresentation() {
        withObservationTracking {
            _ = appModel?.composerMode?.id
            _ = appModel?.composerPresentationRequestID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.synchronizeComposerWindow()
                self?.observeComposerPresentation()
            }
        }
    }

    private func refresh() {
        guard let appModel else { return }
        let isRunning = appModel.runningTimer != nil
        let isConnected = appModel.authenticationState == .signedIn
        let actionColor = isRunning
            ? appModel.timenTheme.appKitAccent
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
            : (!appModel.connectivity.isOnline ? TimenBarError.unsavedMutationMessage
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

private enum ComposerAnchorTarget {
    case entryRow
    case newTimerButton
}

private enum ComposerAttachmentSide: Equatable {
    case leading
    case trailing
}

private enum ComposerAttachmentMetrics {
    static let contentWidth: CGFloat = 520
    static let tailDepth: CGFloat = 14
    static let tailHalfHeight: CGFloat = 14
    static let cornerRadius: CGFloat = 14
    static let windowOverlap: CGFloat = 1
    static let screenMargin: CGFloat = 8
    static let mainFooterHeight: CGFloat = 52
    static let totalWidth = contentWidth + tailDepth
    static let compactHeight: CGFloat = 350
    static let contentSize = NSSize(width: totalWidth, height: compactHeight)
}

@Observable
@MainActor
private final class ComposerAttachmentLayout {
    var tailY: CGFloat = 250
}

private struct AttachedTimerComposerView: View {
    let mode: TimerComposerMode
    let attachment: ComposerAttachmentSide
    let layout: ComposerAttachmentLayout

    var body: some View {
        let bubble = ComposerBubbleShape(attachment: attachment, tailY: layout.tailY)

        TimerComposerView(mode: mode)
            .padding(attachment == .leading ? .leading : .trailing, ComposerAttachmentMetrics.tailDepth)
            .background {
                bubble.fill(Color(nsColor: .windowBackgroundColor))
            }
            .clipShape(bubble)
            .overlay {
                bubble.stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .frame(width: ComposerAttachmentMetrics.totalWidth)
            .accessibilityElement(children: .contain)
    }
}

private struct ComposerBubbleShape: Shape {
    let attachment: ComposerAttachmentSide
    let tailY: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.5
        let top = rect.minY + inset
        let bottom = rect.maxY - inset
        let radius = ComposerAttachmentMetrics.cornerRadius
        let tailHalfHeight = ComposerAttachmentMetrics.tailHalfHeight
        let tailDepth = ComposerAttachmentMetrics.tailDepth
        let minimumMiddle = top + radius + tailHalfHeight
        let maximumMiddle = bottom - radius - tailHalfHeight
        let middle = min(maximumMiddle, max(minimumMiddle, tailY))
        var path = Path()

        switch attachment {
        case .trailing:
            let left = rect.minX + inset
            let right = rect.maxX - tailDepth
            let tailTip = rect.maxX - inset
            path.move(to: CGPoint(x: left + radius, y: top))
            path.addLine(to: CGPoint(x: right - radius, y: top))
            path.addQuadCurve(
                to: CGPoint(x: right, y: top + radius),
                control: CGPoint(x: right, y: top)
            )
            path.addLine(to: CGPoint(x: right, y: middle - tailHalfHeight))
            path.addLine(to: CGPoint(x: tailTip, y: middle))
            path.addLine(to: CGPoint(x: right, y: middle + tailHalfHeight))
            path.addLine(to: CGPoint(x: right, y: bottom - radius))
            path.addQuadCurve(
                to: CGPoint(x: right - radius, y: bottom),
                control: CGPoint(x: right, y: bottom)
            )
            path.addLine(to: CGPoint(x: left + radius, y: bottom))
            path.addQuadCurve(
                to: CGPoint(x: left, y: bottom - radius),
                control: CGPoint(x: left, y: bottom)
            )
            path.addLine(to: CGPoint(x: left, y: top + radius))
            path.addQuadCurve(
                to: CGPoint(x: left + radius, y: top),
                control: CGPoint(x: left, y: top)
            )

        case .leading:
            let left = rect.minX + tailDepth
            let right = rect.maxX - inset
            let tailTip = rect.minX + inset
            path.move(to: CGPoint(x: left + radius, y: top))
            path.addLine(to: CGPoint(x: right - radius, y: top))
            path.addQuadCurve(
                to: CGPoint(x: right, y: top + radius),
                control: CGPoint(x: right, y: top)
            )
            path.addLine(to: CGPoint(x: right, y: bottom - radius))
            path.addQuadCurve(
                to: CGPoint(x: right - radius, y: bottom),
                control: CGPoint(x: right, y: bottom)
            )
            path.addLine(to: CGPoint(x: left + radius, y: bottom))
            path.addQuadCurve(
                to: CGPoint(x: left, y: bottom - radius),
                control: CGPoint(x: left, y: bottom)
            )
            path.addLine(to: CGPoint(x: left, y: middle + tailHalfHeight))
            path.addLine(to: CGPoint(x: tailTip, y: middle))
            path.addLine(to: CGPoint(x: left, y: middle - tailHalfHeight))
            path.addLine(to: CGPoint(x: left, y: top + radius))
            path.addQuadCurve(
                to: CGPoint(x: left + radius, y: top),
                control: CGPoint(x: left, y: top)
            )
        }

        path.closeSubpath()
        return path
    }
}

private final class ComposerAttachmentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
