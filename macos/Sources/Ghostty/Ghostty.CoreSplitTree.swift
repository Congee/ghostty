import Cocoa

extension Ghostty {
    /// A read-only view of the core Zig split tree for a given tab.
    /// Reads directly from core via C API — no Swift-side copy.
    struct CoreSplitTree: Equatable {
        let app: ghostty_app_t
        let tabIndex: UInt32

        /// The version of the tree. Changes on any mutation (split, close, resize, zoom).
        var version: UInt64 {
            ghostty_app_tab_tree_version(app, tabIndex)
        }

        /// Total number of nodes in the tree.
        var nodeCount: UInt16 {
            ghostty_app_tab_node_count(app, tabIndex)
        }

        /// Whether the tree is empty (no surfaces).
        var isEmpty: Bool {
            nodeCount == 0
        }

        /// Whether any node is currently zoomed.
        var isZoomed: Bool {
            ghostty_app_tab_is_zoomed(app, tabIndex)
        }

        /// Whether the root node is a split (more than one surface).
        var isSplit: Bool {
            !isEmpty && !ghostty_app_tab_node_is_leaf(app, tabIndex, 0)
        }

        /// The root node (handle 0).
        var root: Node? {
            guard !isEmpty else { return nil }
            return Node(tree: self, handle: 0)
        }

        /// A node in the core split tree. Reads lazily from C API.
        struct Node: Identifiable, Equatable {
            let tree: CoreSplitTree
            let handle: UInt16

            var id: UInt16 { handle }

            var isLeaf: Bool {
                ghostty_app_tab_node_is_leaf(tree.app, tree.tabIndex, handle)
            }

            /// The surface at this leaf node, or nil if this is a split.
            var surface: ghostty_surface_t? {
                guard isLeaf else { return nil }
                return ghostty_app_tab_node_surface(tree.app, tree.tabIndex, handle)
            }

            /// The SurfaceView for this leaf, recovered from the surface's userdata.
            var surfaceView: Ghostty.SurfaceView? {
                guard let surface else { return nil }
                guard let ud = ghostty_surface_userdata(surface) else { return nil }
                return Unmanaged<Ghostty.SurfaceView>.fromOpaque(ud).takeUnretainedValue()
            }

            /// Split direction (true = horizontal, false = vertical).
            var isHorizontal: Bool {
                ghostty_app_tab_node_is_horizontal(tree.app, tree.tabIndex, handle)
            }

            /// Split ratio (0.0 to 1.0).
            var ratio: Double {
                ghostty_app_tab_node_ratio(tree.app, tree.tabIndex, handle)
            }

            /// Left/start child node.
            var left: Node? {
                guard !isLeaf else { return nil }
                let h = ghostty_app_tab_node_left(tree.app, tree.tabIndex, handle)
                return Node(tree: tree, handle: h)
            }

            /// Right/end child node.
            var right: Node? {
                guard !isLeaf else { return nil }
                let h = ghostty_app_tab_node_right(tree.app, tree.tabIndex, handle)
                return Node(tree: tree, handle: h)
            }

            /// A stable identity for SwiftUI structural diffing.
            var structuralIdentity: String {
                if isLeaf {
                    return "leaf-\(handle)"
                }
                return "split-\(handle)-\(isHorizontal ? "h" : "v")"
            }

            static func == (lhs: Node, rhs: Node) -> Bool {
                lhs.tree == rhs.tree && lhs.handle == rhs.handle
            }
        }

        static func == (lhs: CoreSplitTree, rhs: CoreSplitTree) -> Bool {
            lhs.app == rhs.app && lhs.tabIndex == rhs.tabIndex && lhs.version == rhs.version
        }
    }
}
