import Foundation
import Network
import Observation

@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.timenbar.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }

    isolated deinit { monitor.cancel() }
}
