/**
 * AT-SPI accessibility tree query helper for Ghostty UI tests.
 *
 * Uses @homebridge/dbus-native for direct DBus protocol access
 * to the AT-SPI bus. No subprocess spawning per query.
 */
const DBus = require('@homebridge/dbus-native')

const AT_SPI_SOCKET = '/run/user/1000/at-spi/bus_0'

export interface A11yNode {
  name: string
  role: string
  path: string
  children: A11yNode[]
}

/** Connect to the AT-SPI bus. */
function connect(): any {
  return DBus.createClient({ socket: AT_SPI_SOCKET })
}

/** Call a method on the AT-SPI Accessible interface. */
function callAccessible(
  bus: any,
  dest: string,
  path: string,
  method: string,
  signature?: string,
  body?: any[],
): Promise<any> {
  return new Promise((resolve, reject) => {
    bus.invoke({
      destination: dest,
      path,
      interface: 'org.a11y.atspi.Accessible',
      member: method,
      signature,
      body,
    }, (err: any, result: any) => {
      if (err) reject(err)
      else resolve(result)
    })
  })
}

/** Get a string property from an accessible node. */
function getProperty(
  bus: any,
  dest: string,
  path: string,
  prop: string,
): Promise<string> {
  return new Promise((resolve, reject) => {
    bus.invoke({
      destination: dest,
      path,
      interface: 'org.freedesktop.DBus.Properties',
      member: 'Get',
      signature: 'ss',
      body: ['org.a11y.atspi.Accessible', prop],
    }, (err: any, result: any) => {
      if (err) resolve('')
      else resolve(result?.[1]?.[0] ?? '')
    })
  })
}

/** Find Ghostty's bus name by listing AT-SPI bus connections. */
async function findGhosttyDest(bus: any): Promise<string | null> {
  return new Promise((resolve) => {
    bus.invoke({
      destination: 'org.freedesktop.DBus',
      path: '/org/freedesktop/DBus',
      interface: 'org.freedesktop.DBus',
      member: 'ListNames',
    }, (err: any, names: string[]) => {
      if (err || !names) { resolve(null); return }
      // Find the unique name for ghostty by checking each connection
      // We need to match by process name, which requires GetConnectionUnixProcessID
      // Simpler: iterate children of the registry root
      resolve(null) // Will use registry approach instead
    })
  })
}

/** Get the child at a given index. Returns [dest, path] or null. */
async function getChildAt(
  bus: any,
  dest: string,
  path: string,
  index: number,
): Promise<[string, string] | null> {
  try {
    const result = await callAccessible(bus, dest, path, 'GetChildAtIndex', 'i', [index])
    // Result is [busName, objectPath]
    if (!result || !result[0] || !result[1]) return null
    return [result[0], result[1]]
  } catch {
    return null
  }
}

/** Walk the accessible tree from a node, building an A11yNode. */
async function walkTree(
  bus: any,
  dest: string,
  path: string,
  maxDepth = 6,
  depth = 0,
): Promise<A11yNode> {
  const [name, role] = await Promise.all([
    getProperty(bus, dest, path, 'Name').catch(() => ''),
    callAccessible(bus, dest, path, 'GetRoleName').catch(() => 'unknown'),
  ])

  const node: A11yNode = {
    name: typeof name === 'string' ? name : '',
    role: typeof role === 'string' ? role : 'unknown',
    path,
    children: [],
  }

  if (depth >= maxDepth) return node

  for (let i = 0; i < 20; i++) {
    const child = await getChildAt(bus, dest, path, i)
    if (!child) break
    // Child may be on a different bus name
    node.children.push(await walkTree(bus, child[0], child[1], maxDepth, depth + 1))
  }

  return node
}

/** Get the PID for a DBus bus name. */
async function getPidForBusName(bus: any, busName: string): Promise<number | null> {
  return new Promise((resolve) => {
    bus.invoke({
      destination: 'org.freedesktop.DBus',
      path: '/org/freedesktop/DBus',
      interface: 'org.freedesktop.DBus',
      member: 'GetConnectionUnixProcessID',
      signature: 's',
      body: [busName],
    }, (err: any, pid: number) => {
      if (err) resolve(null)
      else resolve(pid)
    })
  })
}

/** Get Ghostty's full accessibility tree by PID. */
export async function getGhosttyTree(pid?: number): Promise<A11yNode | null> {
  const bus = connect()

  try {
    const registryDest = 'org.a11y.atspi.Registry'
    const registryRoot = '/org/a11y/atspi/accessible/root'

    // Iterate registry children to find Ghostty by matching PID.
    for (let i = 0; i < 20; i++) {
      const child = await getChildAt(bus, registryDest, registryRoot, i)
      if (!child) break

      // Match by PID if provided
      if (pid) {
        const childPid = await getPidForBusName(bus, child[0])
        if (childPid !== pid) continue
      }

      // Found the app — walk its first child (the window)
      const window = await getChildAt(bus, child[0], child[1], 0)
      if (!window) continue
      return await walkTree(bus, window[0], window[1])
    }

    return null
  } finally {
    bus.connection.end()
  }
}

/** Find all nodes matching a role name. */
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
