import Foundation
import Network
import ReedApplication

final class AppleCloudNetworkPolicy: CloudNetworkPolicy, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var connected = false
    private var wifi = false
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { connected = path.status == .satisfied; wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) }
        }
        monitor.start(queue: DispatchQueue(label: "reed.cloud.network"))
    }
    deinit { monitor.cancel() }
    func allowsTransfer(wifiOnly: Bool) -> Bool { lock.withLock { connected && (!wifiOnly || wifi) } }
}
