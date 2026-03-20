#if os(iOS) || os(macOS)
// BonjourBrowser — Discovers ghostty-daemon instances on the local network
// using Network.framework's NWBrowser (Bonjour/DNS-SD).

import Foundation
import Network

/// A discovered daemon on the network.
struct DiscoveredDaemon: Identifiable, Hashable {
    let id: String // endpoint description
    let name: String
    let endpoint: NWEndpoint

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredDaemon, rhs: DiscoveredDaemon) -> Bool {
        lhs.id == rhs.id
    }
}

/// Browses for _ghostty._tcp services on the local network.
@MainActor
class BonjourBrowser: ObservableObject {
    @Published var daemons: [DiscoveredDaemon] = []
    @Published var isSearching = false

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "bonjour-browser")

    func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_ghostty._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: params)

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.daemons = results.map { result in
                    let name: String
                    switch result.endpoint {
                    case .service(let n, _, _, _):
                        name = n
                    default:
                        name = "\(result.endpoint)"
                    }
                    return DiscoveredDaemon(
                        id: "\(result.endpoint)",
                        name: name,
                        endpoint: result.endpoint
                    )
                }
            }
        }

        b.start(queue: queue)
        browser = b
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}
#endif
