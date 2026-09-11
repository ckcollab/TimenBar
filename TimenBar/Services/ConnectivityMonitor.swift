import Foundation
import Network
import Observation

@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline: Bool
    private(set) var lastReachabilityFailed = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.timenbar.connectivity")

    /// Path is down, or a Timen request just failed with a no-internet error.
    var isUnreachable: Bool { !isOnline || lastReachabilityFailed }

    init(initiallyOnline: Bool = true, startMonitoring: Bool = true) {
        isOnline = initiallyOnline
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                // A path that just came back is a better signal than the last
                // failed request. Stay latched if Wi-Fi never dropped.
                if satisfied, !self.isOnline {
                    self.lastReachabilityFailed = false
                }
                self.isOnline = satisfied
            }
        }
        if startMonitoring { monitor.start(queue: queue) }
    }

    isolated deinit { monitor.cancel() }

    func noteReachabilityFailure() {
        lastReachabilityFailed = true
    }

    func noteReachabilitySuccess() {
        lastReachabilityFailed = false
    }

    nonisolated static func isInternetFailure(_ error: Error) -> Bool {
        let internetFailureCodes: Set<URLError.Code> = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .dnsLookupFailed,
            .cannotFindHost,
            .cannotConnectToHost,
            .dataNotAllowed,
            .internationalRoamingOff,
            .timedOut,
        ]
        if case TimenBarError.networkUnavailable = error { return true }
        var current: Error? = error
        while let err = current {
            if let urlError = err as? URLError, internetFailureCodes.contains(urlError.code) {
                return true
            }
            let ns = err as NSError
            if ns.domain == NSURLErrorDomain,
               internetFailureCodes.contains(URLError.Code(rawValue: ns.code))
            {
                return true
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }
}
