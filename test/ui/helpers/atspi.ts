/**
 * AT-SPI accessibility tree query helper for Ghostty UI tests.
 *
 * Queries the GTK accessibility tree via busctl on the AT-SPI bus.
 * No pyatspi needed — pure DBus calls.
 */
import { $ } from 'bun'

const AT_SPI_BUS = 'unix:path=/run/user/1000/at-spi/bus_0'

/**
 * AT-SPI roles from the Accessibility specification.
 * See: https://docs.gtk.org/atspi2/enum.Role.html
 */
export enum Role {
  INVALID = 0,
  ACCELERATOR_LABEL = 1,
  ALERT = 2,
  ANIMATION = 3,
  APPLICATION = 75,
  ARROW = 4,
  CALENDAR = 5,
  CANVAS = 6,
  CHECK_BOX = 7,
  CHECK_MENU_ITEM = 8,
  COLOR_CHOOSER = 9,
  COLUMN_HEADER = 10,
  COMBO_BOX = 11,
  DATE_EDITOR = 12,
  DESKTOP_FRAME = 14,
  DESKTOP_ICON = 13,
  DIAL = 15,
  DIALOG = 25,
  DIRECTORY_PANE = 16,
  DRAWING_AREA = 17,
  EXTENDED = 70,
  FILE_CHOOSER = 18,
  FILLER = 19,
  FOCUS_TRAVERSABLE = 20,
  FONT_CHOOSER = 21,
  FRAME = 23,
  GLASS_PANE = 24,
  HEADER = 76,
  HEADING = 77,
  HTML_CONTAINER = 26,
  ICON = 27,
  IMAGE = 28,
  INTERNAL_FRAME = 29,
  LABEL = 30,
  LAYERED_PANE = 31,
  LIST = 32,
  LIST_ITEM = 33,
  MENU = 34,
  MENU_BAR = 35,
  MENU_ITEM = 36,
  OPTION_PANE = 37,
  PAGE = 78,
  PAGE_TAB = 38,
  PAGE_TAB_LIST = 81,
  PANEL = 39,
  PASSWORD_TEXT = 40,
  POPUP_MENU = 41,
  PROGRESS_BAR = 42,
  PUSH_BUTTON = 43,
  RADIO_BUTTON = 44,
  RADIO_MENU_ITEM = 45,
  ROOT_PANE = 46,
  ROW_HEADER = 47,
  SCROLL_BAR = 48,
  SCROLL_PANE = 49,
  SEPARATOR = 56,
  SLIDER = 50,
  SPIN_BUTTON = 52,
  SPLIT_PANE = 53,
  STATUS_BAR = 54,
  TABLE = 55,
  TABLE_CELL = 57,
  TABLE_COLUMN_HEADER = 58,
  TABLE_ROW_HEADER = 59,
  TEAROFF_MENU_ITEM = 60,
  TERMINAL = 61,
  TEXT = 62,
  TOGGLE_BUTTON = 63,
  TOOL_BAR = 64,
  TOOL_TIP = 65,
  TREE = 66,
  TREE_TABLE = 67,
  UNKNOWN = 68,
  VIEWPORT = 69,
  WIDGET = 99,
  WINDOW = 22,
}

function roleName(role: number): string {
  const entry = Object.entries(Role).find(([_, v]) => v === role)
  return entry ? entry[0].toLowerCase() : `unknown(${role})`
}

/** Find Ghostty's bus name on the AT-SPI bus. */
async function findGhosttyBus(): Promise<string | null> {
  const result = await $`busctl --address=${AT_SPI_BUS} list`.text()
  const line = result.split('\n').find(l => l.includes('ghostty'))
  return line?.split(/\s+/)[0] ?? null
}

/** Get a property from an accessible node. */
async function getProp(bus: string, path: string, prop: string): Promise<string> {
  const result = await $`busctl --address=${AT_SPI_BUS} get-property ${bus} ${path} org.a11y.atspi.Accessible ${prop}`.text().catch(() => '')
  return result.replace(/^s "/, '').replace(/"$/, '').trim()
}

/** Call a method on an accessible node. */
async function callMethod(bus: string, path: string, method: string, ...args: string[]): Promise<string> {
  return await $`busctl --address=${AT_SPI_BUS} call ${bus} ${path} org.a11y.atspi.Accessible ${method} ${args}`.text().catch(() => '')
}

/** Get the role of an accessible node. */
async function getRole(bus: string, path: string): Promise<number> {
  const result = await callMethod(bus, path, 'GetRole')
  return parseInt(result.split(' ')[1] ?? '0')
}

/** Get the child at index. Returns [childBus, childPath] or null. */
async function getChildAt(bus: string, path: string, index: number): Promise<[string, string] | null> {
  const result = await callMethod(bus, path, 'GetChildAtIndex', 'i', String(index))
  if (result.includes('Call failed') || result.includes('Error')) return null
  const parts = result.match(/"([^"]+)"/g)
  if (!parts || parts.length < 2) return null
  return [parts[0].replace(/"/g, ''), parts[1].replace(/"/g, '')]
}

export interface A11yNode {
  name: string
  role: string
  roleNum: number
  path: string
  children: A11yNode[]
}

/** Walk the accessible tree from a given node. */
async function walkTree(bus: string, path: string, maxDepth = 6, depth = 0): Promise<A11yNode> {
  const name = await getProp(bus, path, 'Name')
  const roleNum = await getRole(bus, path)
  const node: A11yNode = {
    name,
    role: roleName(roleNum),
    roleNum,
    path,
    children: [],
  }

  if (depth >= maxDepth) return node

  for (let i = 0; i < 20; i++) {
    const child = await getChildAt(bus, path, i)
    if (!child) break
    node.children.push(await walkTree(child[0], child[1], maxDepth, depth + 1))
  }

  return node
}

/** Get Ghostty's full accessibility tree. */
export async function getGhosttyTree(): Promise<A11yNode | null> {
  const bus = await findGhosttyBus()
  if (!bus) return null

  const root = await getChildAt(bus, '/org/a11y/atspi/accessible/root', 0)
  if (!root) return null

  return walkTree(root[0], root[1])
}

/** Find all nodes matching a role in the tree. */
export function findByRole(tree: A11yNode, role: string): A11yNode[] {
  const results: A11yNode[] = []
  if (tree.role === role) results.push(tree)
  for (const child of tree.children) {
    results.push(...findByRole(child, role))
  }
  return results
}

/** Find all nodes matching a name substring. */
export function findByName(tree: A11yNode, name: string): A11yNode[] {
  const results: A11yNode[] = []
  if (tree.name.includes(name)) results.push(tree)
  for (const child of tree.children) {
    results.push(...findByName(child, name))
  }
  return results
}

/** Count terminal panes (for verifying splits). */
export function countTerminals(tree: A11yNode): number {
  return findByRole(tree, 'widget').filter(n =>
    // Terminal surfaces are custom widgets at leaf level
    n.children.length === 0 || n.children.every(c => c.role === 'widget')
  ).length
}

/** Check if a separator (split divider) exists. */
export function hasSplitDivider(tree: A11yNode): boolean {
  return findByRole(tree, 'separator').length > 0
}

/** Print tree for debugging. */
export function printTree(node: A11yNode, indent = 0): void {
  const pad = '  '.repeat(indent)
  const nameStr = node.name ? ` "${node.name}"` : ''
  console.log(`${pad}[${node.role}]${nameStr}`)
  for (const child of node.children) {
    printTree(child, indent + 1)
  }
}
