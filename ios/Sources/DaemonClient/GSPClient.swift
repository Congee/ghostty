#if os(iOS)
// GSPClient — Swift implementation of the GSP (Ghostty Sync Protocol) client.
// Connects to a ghostty-daemon over TCP or Unix socket, handles auth,
// and provides async session management.

import Foundation
import Network
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// GSP message types matching Protocol.zig MessageType enum.
enum GSPMessageType: UInt8 {
    // Client -> Server
    case auth = 0x01
    case listSessions = 0x02
    case attach = 0x03
    case detach = 0x04
    case create = 0x05
    case input = 0x06
    case resize = 0x07
    case destroy = 0x08
    case scroll = 0x0a

    // Server -> Client
    case authChallenge = 0x09
    case authOk = 0x80
    case authFail = 0x81
    case sessionList = 0x82
    case fullState = 0x83
    case delta = 0x84
    case attached = 0x85
    case detached = 0x86
    case errorMsg = 0x87
    case sessionCreated = 0x88
    case sessionExited = 0x89
    case scrollData = 0x8a
    case clipboard = 0x8b
    case image = 0x8c
}

/// A cell in the wire format (12 bytes, matching Protocol.WireCell).
struct WireCell {
    var codepoint: UInt32 = 0
    var fg_r: UInt8 = 0
    var fg_g: UInt8 = 0
    var fg_b: UInt8 = 0
    var bg_r: UInt8 = 0
    var bg_g: UInt8 = 0
    var bg_b: UInt8 = 0
    var styleFlags: UInt8 = 0
    var wide: UInt8 = 0

    var hasFg: Bool { (styleFlags & 0x20) != 0 }
    var hasBg: Bool { (styleFlags & 0x40) != 0 }
    var isBold: Bool { (styleFlags & 0x01) != 0 }
    var isItalic: Bool { (styleFlags & 0x02) != 0 }
    var isUnderline: Bool { (styleFlags & 0x04) != 0 }

    var character: Character {
        guard let scalar = Unicode.Scalar(codepoint), codepoint >= 0x20 else {
            return " "
        }
        return Character(scalar)
    }
}

/// Session metadata from LIST_SESSIONS.
struct SessionInfo: Identifiable {
    let id: UInt32
    let name: String
    let title: String
    let pwd: String
    let attached: Bool
    let childExited: Bool
}

/// Screen state from FULL_STATE/DELTA messages.
class ScreenState: ObservableObject {
    @Published var rows: UInt16 = 0
    @Published var cols: UInt16 = 0
    @Published var cells: [WireCell] = []
    @Published var cursorX: UInt16 = 0
    @Published var cursorY: UInt16 = 0
    @Published var cursorVisible: Bool = true

    func getCell(col: Int, row: Int) -> WireCell {
        let idx = row * Int(cols) + col
        guard idx >= 0, idx < cells.count else { return WireCell() }
        return cells[idx]
    }
}

/// GSP protocol client using Network.framework.
@MainActor
class GSPClient: ObservableObject {
    @Published var connected = false
    @Published var authenticated = false
    @Published var sessions: [SessionInfo] = []
    @Published var screen = ScreenState()
    @Published var attachedSessionId: UInt32? = nil
    @Published var lastError: String? = nil

    private var connection: NWConnection?
    private var authKey: SymmetricKey? = nil
    private let queue = DispatchQueue(label: "gsp-client", qos: .userInteractive)

    // GSP constants (nonisolated for Sendable closures)
    private nonisolated static let magic: [UInt8] = [0x47, 0x53] // "GS"
    private nonisolated static let headerLen = 7

    // MARK: - Connection

    func connect(host: String, port: UInt16, authKey: String = "") {
        self.authKey = authKey.isEmpty ? nil : SymmetricKey(data: Data(authKey.utf8))
        let hasAuth = !authKey.isEmpty
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        connection = NWConnection(host: nwHost, port: nwPort, using: params)
        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.connected = true
                    self?.lastError = nil
                    self?.startReading()
                    if hasAuth {
                        self?.sendAuth()
                    } else {
                        self?.authenticated = true
                    }
                case .failed(let error):
                    self?.connected = false
                    self?.lastError = "Connection failed: \(error)"
                case .cancelled:
                    self?.connected = false
                default:
                    break
                }
            }
        }
        connection?.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connected = false
        authenticated = false
        attachedSessionId = nil
    }

    // MARK: - Commands

    func listSessions() {
        sendMessage(type: .listSessions, payload: Data())
    }

    func createSession(cols: UInt16 = 80, rows: UInt16 = 24) {
        var payload = Data(count: 4)
        payload.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: cols.littleEndian, as: UInt16.self)
            buf.storeBytes(of: rows.littleEndian, toByteOffset: 2, as: UInt16.self)
        }
        sendMessage(type: .create, payload: payload)
    }

    func attach(sessionId: UInt32) {
        attachedSessionId = sessionId
        var payload = Data(count: 4)
        payload.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: sessionId.littleEndian, as: UInt32.self)
        }
        sendMessage(type: .attach, payload: payload)
    }

    func detach() {
        sendMessage(type: .detach, payload: Data())
        attachedSessionId = nil
        screen.cells = []
        screen.rows = 0
        screen.cols = 0
    }

    func sendInput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        sendMessage(type: .input, payload: data)
    }

    func sendInputBytes(_ data: Data) {
        sendMessage(type: .input, payload: data)
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        var payload = Data(count: 4)
        payload.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: cols.littleEndian, as: UInt16.self)
            buf.storeBytes(of: rows.littleEndian, toByteOffset: 2, as: UInt16.self)
        }
        sendMessage(type: .resize, payload: payload)
    }

    // MARK: - Auth (HMAC challenge-response)

    private func sendAuth() {
        // Send empty AUTH to request challenge
        sendMessage(type: .auth, payload: Data())
    }

    private func handleAuthChallenge(_ payload: Data) {
        guard payload.count == 32 else {
            lastError = "Invalid challenge length"
            return
        }
        guard let key = authKey else {
            lastError = "No auth key configured"
            return
        }

        // HMAC-SHA256(key, challenge)
        let hmac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        sendMessage(type: .auth, payload: Data(hmac))
    }

    // MARK: - Protocol I/O

    private func sendMessage(type: GSPMessageType, payload: Data) {
        var header = Data(count: Self.headerLen)
        header[0] = Self.magic[0]
        header[1] = Self.magic[1]
        header[2] = type.rawValue
        let len = UInt32(payload.count).littleEndian
        header.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: len, toByteOffset: 3, as: UInt32.self)
        }

        let message = header + payload
        connection?.send(content: message, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.lastError = "Send failed: \(error)"
                }
            }
        })
    }

    private func startReading() {
        readHeader()
    }

    private func readHeader() {
        let headerLen = Self.headerLen
        let magic = Self.magic
        connection?.receive(minimumIncompleteLength: headerLen, maximumLength: headerLen) {
            [weak self] content, _, isComplete, error in
            guard let self, let data = content, data.count == headerLen else {
                if isComplete {
                    Task { @MainActor in self?.disconnect() }
                }
                return
            }

            // Validate magic
            guard data[0] == magic[0], data[1] == magic[1] else {
                Task { @MainActor in
                    self.lastError = "Invalid magic bytes"
                    self.disconnect()
                }
                return
            }

            let msgType = data[2]
            let payloadLen = data.withUnsafeBytes { buf -> UInt32 in
                buf.loadUnaligned(fromByteOffset: 3, as: UInt32.self)
            }
            let len = UInt32(littleEndian: payloadLen)

            if len == 0 {
                Task { @MainActor in
                    self.handleMessage(type: msgType, payload: Data())
                    self.readHeader()
                }
            } else {
                Task { @MainActor in
                    self.readPayload(type: msgType, length: Int(len))
                }
            }
        }
    }

    private func readPayload(type msgType: UInt8, length: Int) {
        connection?.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] content, _, isComplete, error in
            guard let self, let data = content else {
                if isComplete {
                    Task { @MainActor in self?.disconnect() }
                }
                return
            }

            Task { @MainActor in
                self.handleMessage(type: msgType, payload: data)
                self.readHeader()
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(type: UInt8, payload: Data) {
        guard let msgType = GSPMessageType(rawValue: type) else { return }

        // Already on @MainActor via Task in readHeader/readPayload callbacks.
        switch msgType {
        case .authChallenge:
            handleAuthChallenge(payload)
        case .authOk:
            authenticated = true
            lastError = nil
        case .authFail:
            lastError = "Authentication failed"
        case .sessionList:
            parseSessionList(payload)
        case .sessionCreated:
            if payload.count >= 4 {
                let id = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                let sessionId = UInt32(littleEndian: id)
                attachedSessionId = sessionId
                attach(sessionId: sessionId)
            }
        case .attached:
            break // fullState follows immediately
        case .fullState:
            applyFullState(payload)
        case .delta:
            applyDelta(payload)
        case .detached:
            attachedSessionId = nil
        case .errorMsg:
            lastError = String(data: payload, encoding: .utf8) ?? "Unknown error"
        case .sessionExited:
            attachedSessionId = nil
        case .clipboard:
            handleClipboard(payload)
        default:
            break
        }
    }

    // MARK: - State Parsing

    private func parseSessionList(_ data: Data) {
        guard data.count >= 4 else { return }
        let count = data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }

        var offset = 4
        var entries: [SessionInfo] = []

        for _ in 0..<count {
            guard offset + 4 <= data.count else { break }
            let id = data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            offset += 4

            func readString() -> String {
                guard offset + 2 <= data.count else { return "" }
                let len = data.withUnsafeBytes {
                    Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                }
                offset += 2
                guard offset + len <= data.count else { return "" }
                let str = String(data: data[offset..<offset+len], encoding: .utf8) ?? ""
                offset += len
                return str
            }

            let name = readString()
            let title = readString()
            let pwd = readString()

            guard offset < data.count else { break }
            let flags = data[offset]
            offset += 1

            entries.append(SessionInfo(
                id: id,
                name: name,
                title: title,
                pwd: pwd,
                attached: (flags & 0x01) != 0,
                childExited: (flags & 0x02) != 0
            ))
        }

        sessions = entries
    }

    private func applyFullState(_ data: Data) {
        // Header: rows(2) + cols(2) + cursor_x(2) + cursor_y(2) + cursor_visible(1) + padding(3)
        guard data.count >= 12 else { return }

        let rows = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)) }
        let cols = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self)) }
        let cursorX = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self)) }
        let cursorY = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self)) }
        let cursorVisible = data[8] != 0

        let cellCount = Int(rows) * Int(cols)
        let expectedSize = 12 + cellCount * 12

        guard data.count >= expectedSize else { return }

        var cells = [WireCell](repeating: WireCell(), count: cellCount)
        data.withUnsafeBytes { buf in
            for i in 0..<cellCount {
                let base = 12 + i * 12
                cells[i] = WireCell(
                    codepoint: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: base, as: UInt32.self)),
                    fg_r: buf[base + 4],
                    fg_g: buf[base + 5],
                    fg_b: buf[base + 6],
                    bg_r: buf[base + 7],
                    bg_g: buf[base + 8],
                    bg_b: buf[base + 9],
                    styleFlags: buf[base + 10],
                    wide: buf[base + 11]
                )
            }
        }

        screen.rows = rows
        screen.cols = cols
        screen.cells = cells
        screen.cursorX = cursorX
        screen.cursorY = cursorY
        screen.cursorVisible = cursorVisible
        attachedSessionId = attachedSessionId // trigger publish
    }

    private func applyDelta(_ data: Data) {
        guard data.count >= 8 else { return }

        let cursorX = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self)) }
        let cursorY = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self)) }
        let cursorVisible = data[6] != 0
        let numRows = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)) }

        screen.cursorX = cursorX
        screen.cursorY = cursorY
        screen.cursorVisible = cursorVisible

        var offset = 8
        for _ in 0..<numRows {
            guard offset + 4 <= data.count else { break }
            let rowIndex = data.withUnsafeBytes {
                Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            }
            let numCols = data.withUnsafeBytes {
                Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)))
            }
            offset += 4

            let rowCellBytes = numCols * 12
            guard offset + rowCellBytes <= data.count else { break }
            guard rowIndex < screen.rows, numCols <= screen.cols else {
                offset += rowCellBytes
                continue
            }

            let dstStart = rowIndex * Int(screen.cols)
            data.withUnsafeBytes { buf in
                for c in 0..<numCols {
                    let base = offset + c * 12
                    screen.cells[dstStart + c] = WireCell(
                        codepoint: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: base, as: UInt32.self)),
                        fg_r: buf[base + 4],
                        fg_g: buf[base + 5],
                        fg_b: buf[base + 6],
                        bg_r: buf[base + 7],
                        bg_g: buf[base + 8],
                        bg_b: buf[base + 9],
                        styleFlags: buf[base + 10],
                        wide: buf[base + 11]
                    )
                }
            }
            offset += rowCellBytes
        }

        screen.objectWillChange.send()
    }

    private func handleClipboard(_ data: Data) {
        #if os(iOS)
        if let str = String(data: data, encoding: .utf8) {
            // Decode base64 clipboard content
            if let decoded = Data(base64Encoded: str),
               let text = String(data: decoded, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
        #endif
    }
}
#endif
