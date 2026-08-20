import Foundation
import Network
import Observation

@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline: Bool
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.timenbar.connectivity")

    init(initiallyOnline: Bool = true, startMonitoring: Bool = true) {
        isOnline = initiallyOnline
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        if startMonitoring { monitor.start(queue: queue) }
    }

    isolated deinit { monitor.cancel() }
}
