// RemoteTerminalView — SwiftUI view that renders the daemon's cell grid.
// Uses a Canvas for efficient character rendering.

import SwiftUI

struct RemoteTerminalView: View {
    @ObservedObject var screen: ScreenState
    /// Called when the view resizes — sends new dimensions to daemon.
    var onResize: ((UInt16, UInt16) -> Void)? = nil

    private let monoFont = Font.system(size: 14, design: .monospaced)
    private let cellWidth: CGFloat = 8.4
    private let cellHeight: CGFloat = 17

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let cols = Int(screen.cols)
                let rows = Int(screen.rows)
                guard cols > 0, rows > 0, screen.cells.count == cols * rows else { return }

                // Background
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                // Pre-resolve a template text for the monospaced font (avoids per-cell CTFont alloc)
                let templateResolved = context.resolve(Text(" ").font(monoFont))
                _ = templateResolved // font is cached by context after first resolve

                // Draw cells
                for row in 0..<rows {
                    for col in 0..<cols {
                        let cell = screen.getCell(col: col, row: row)
                        let x = CGFloat(col) * cellWidth
                        let y = CGFloat(row) * cellHeight

                        // Background color
                        if cell.hasBg {
                            let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
                            context.fill(
                                Path(rect),
                                with: .color(Color(
                                    red: Double(cell.bg_r) / 255,
                                    green: Double(cell.bg_g) / 255,
                                    blue: Double(cell.bg_b) / 255
                                ))
                            )
                        }

                        // Character — skip spaces for performance
                        let cp = cell.codepoint
                        guard cp > 0x20, let scalar = Unicode.Scalar(cp) else { continue }

                        let fgColor: Color = cell.hasFg
                            ? Color(red: Double(cell.fg_r)/255, green: Double(cell.fg_g)/255, blue: Double(cell.fg_b)/255)
                            : .white

                        var text = Text(String(Character(scalar)))
                            .font(monoFont)
                            .foregroundColor(fgColor)

                        if cell.isBold { text = text.bold() }
                        if cell.isItalic { text = text.italic() }

                        context.draw(
                            context.resolve(text),
                            at: CGPoint(x: x, y: y),
                            anchor: .topLeading
                        )
                    }
                }

                // Cursor
                if screen.cursorVisible {
                    let cx = CGFloat(screen.cursorX) * cellWidth
                    let cy = CGFloat(screen.cursorY) * cellHeight
                    let cursorRect = CGRect(x: cx, y: cy, width: cellWidth, height: cellHeight)
                    context.fill(Path(cursorRect), with: .color(.white.opacity(0.5)))
                }
            }
            .onChange(of: geo.size) { _, newSize in
                let newCols = max(1, UInt16(newSize.width / cellWidth))
                let newRows = max(1, UInt16(newSize.height / cellHeight))
                if newCols != screen.cols || newRows != screen.rows {
                    onResize?(newCols, newRows)
                }
            }
        }
        .background(.black)
    }
}
