import Network
import Observation

@MainActor protocol ConnectivityProviding {
    var available: Bool { get }
    var checked: Bool { get }
}
@MainActor @Observable final class ConnectivityMonitor: ConnectivityProviding {
    private(set) var available = false
    private(set) var checked = false
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.available = available; self?.checked = true }
        }
        monitor.start(queue: DispatchQueue(label: "BabyCryMonitor.connectivity"))
    }
    deinit { monitor.cancel() }
}
