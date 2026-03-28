// ConnectionStore — Local persistence for saved nodes and connection history.

import Foundation
import SwiftUI

struct SavedNode: Identifiable, Codable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16 = 7337
    var lastConnected: Date?
}

enum HistoryStatus: String, Codable {
    case connected = "Connected"
    case disconnected = "Disconnected"
    case timedOut = "Timed Out"
}

struct ConnectionHistoryEntry: Identifiable, Codable {
    var id = UUID()
    var nodeName: String
    var host: String
    var startTime: Date
    var endTime: Date?
    var status: HistoryStatus = .connected

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    var durationString: String {
        guard let d = duration else { return "Active" }
        let h = Int(d) / 3600
        let m = (Int(d) % 3600) / 60
        let s = Int(d) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var relativeTimeString: String {
        Self.relativeFormatter.localizedString(for: startTime, relativeTo: Date())
    }
}

@MainActor
class ConnectionStore: ObservableObject {
    @Published var savedNodes: [SavedNode] = []
    @Published var history: [ConnectionHistoryEntry] = []

    private let nodesKey = "kinetic.savedNodes"
    private let historyKey = "kinetic.connectionHistory"
    private let maxHistory = 50

    init() {
        loadNodes()
        loadHistory()
    }

    // MARK: - Nodes

    func addNode(_ node: SavedNode) {
        savedNodes.append(node)
        saveNodes()
    }

    func removeNode(at offsets: IndexSet) {
        savedNodes.remove(atOffsets: offsets)
        saveNodes()
    }

    func updateNodeLastConnected(_ node: SavedNode) {
        if let idx = savedNodes.firstIndex(where: { $0.id == node.id }) {
            savedNodes[idx].lastConnected = Date()
            saveNodes()
        }
    }

    // MARK: - History

    func recordConnection(nodeName: String, host: String) -> UUID {
        let entry = ConnectionHistoryEntry(
            nodeName: nodeName,
            host: host,
            startTime: Date()
        )
        history.insert(entry, at: 0)
        if history.count > maxHistory {
            history = Array(history.prefix(maxHistory))
        }
        saveHistory()
        return entry.id
    }

    func endConnection(id: UUID, status: HistoryStatus = .disconnected) {
        if let idx = history.firstIndex(where: { $0.id == id }) {
            history[idx].endTime = Date()
            history[idx].status = status
            saveHistory()
        }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    // MARK: - Persistence

    private func loadNodes() {
        guard let data = UserDefaults.standard.data(forKey: nodesKey),
              let nodes = try? JSONDecoder().decode([SavedNode].self, from: data) else { return }
        savedNodes = nodes
    }

    private func saveNodes() {
        guard let data = try? JSONEncoder().encode(savedNodes) else { return }
        UserDefaults.standard.set(data, forKey: nodesKey)
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let entries = try? JSONDecoder().decode([ConnectionHistoryEntry].self, from: data) else { return }
        history = entries
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }
}
