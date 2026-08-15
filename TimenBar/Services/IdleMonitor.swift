import AppKit
import CoreGraphics
import Foundation
import Observation

struct IdlePromptPolicy: Sendable {
    var threshold: TimeInterval
    var notBefore: Date? = nil
    private(set) var isArmed = true

    mutating func observe(idleSeconds: TimeInterval, now: Date) -> Date? {
        let eligibleSeconds = notBefore.map { max(0, now.timeIntervalSince($0)) } ?? idleSeconds
        let effectiveIdleSeconds = min(idleSeconds, eligibleSeconds)
        if effectiveIdleSeconds < 2 { isArmed = true }
        guard isArmed, effectiveIdleSeconds >= threshold else { return nil }
        isArmed = false
        return now.addingTimeInterval(-effectiveIdleSeconds)
    }

    mutating func suppressUntilActivity() { isArmed = false }
}

@MainActor
@Observable
final class IdleMonitor {
    private(set) var lastIdleSeconds: TimeInterval = 0
    private(set) var isPromptArmed = true

    private var pollTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private let idleProvider: @Sendable () -> TimeInterval
    private var policy = IdlePromptPolicy(threshold: 600)

    init(idleProvider: @escaping @Sendable () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
    }) {
        self.idleProvider = idleProvider
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lastIdleSeconds = self?.idleProvider() ?? 0 }
            })
        }
    }

    isolated deinit {
        pollTask?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.forEach(center.removeObserver)
    }

    func start(threshold: TimeInterval, notBefore: Date, onIdle: @escaping @MainActor (Date) -> Void) {
        stop()
        policy = IdlePromptPolicy(threshold: threshold, notBefore: notBefore)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                lastIdleSeconds = idleProvider()
                if let idleStartedAt = policy.observe(idleSeconds: lastIdleSeconds, now: .now) {
                    isPromptArmed = false
                    onIdle(idleStartedAt)
                } else {
                    isPromptArmed = policy.isArmed
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func suppressUntilActivity() {
        policy.suppressUntilActivity()
        isPromptArmed = false
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        lastIdleSeconds = 0
        isPromptArmed = true
    }
}
