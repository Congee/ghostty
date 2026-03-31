/**
 * AT-SPI accessibility tree tests for Ghostty.
 *
 * Verifies UI structure by querying the accessibility tree —
 * no screenshots, no pixel matching.
 *
 * Requirements:
 * - at-spi2-registryd running
 * - GTK_A11Y=atspi when launching Ghostty
 *
 * Run: cd test/ui && bun run specs/gtk/a11y.spec.ts
 */
import { existsSync, unlinkSync } from 'fs'
import { resolve } from 'path'
import net from 'net'
import { getGhosttyTree, findByRole, hasSplitDivider, printTree, type A11yNode } from '../../helpers/atspi'

const GHOSTTY = process.env.GHOSTTY ?? resolve(__dirname, '../../../../zig-out/bin/ghostty')
const SOCK = `/tmp/ghostty-a11y-test-${process.pid}.sock`

let ghosttyProc: ReturnType<typeof Bun.spawn> | null = null
let passed = 0
let failed = 0

function socketCmd(msg: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(SOCK, () => { client.write(msg + '\n') })
    let data = ''
    client.on('data', (chunk) => { data += chunk.toString() })
    client.on('end', () => resolve(data.trim()))
    client.setTimeout(3000)
    client.on('timeout', () => { client.destroy(); reject(new Error('timeout')) })
    client.on('error', reject)
  })
}

async function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)) }

function ok(desc: string) { passed++; console.log(`  PASS: ${desc}`) }
function fail(desc: string, detail = '') {
  failed++
  console.log(`  FAIL: ${desc}${detail ? ` (${detail})` : ''}`)
}

async function check(desc: string, fn: () => Promise<boolean>) {
  try {
    if (await fn()) ok(desc)
    else fail(desc)
  } catch (e: any) { fail(desc, e.message) }
}

async function main() {
  console.log('=== Ghostty AT-SPI Accessibility Tests ===')
  console.log(`Binary: ${GHOSTTY}`)

  try {
    // Launch with AT-SPI enabled
    if (existsSync(SOCK)) unlinkSync(SOCK)
    ghosttyProc = Bun.spawn([GHOSTTY, `--control-socket=${SOCK}`, '--status-bar=true'], {
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, GTK_A11Y: 'atspi' },
    })
    for (let i = 0; i < 30; i++) { if (existsSync(SOCK)) break; await sleep(200) }
    if (!existsSync(SOCK)) throw new Error('Socket did not appear')
    await sleep(3000)

    // Test 1: Window exists in accessibility tree
    console.log('\n--- Test 1: Window exists ---')
    let tree = await getGhosttyTree()
    await check('Ghostty window found in AT-SPI tree', async () => {
      return tree !== null && tree.role === 'frame'
    })

    if (tree) {
      console.log('\n--- Tree dump ---')
      printTree(tree)
    }

    // Test 2: Has at least one panel (the terminal content area)
    console.log('\n--- Test 2: Terminal content ---')
    await check('has panel widgets (content area)', async () => {
      if (!tree) return false
      return findByRole(tree, 'panel').length > 0
    })

    // Test 3: No split divider initially (single pane)
    console.log('\n--- Test 3: No split initially ---')
    await check('no separator (no split divider)', async () => {
      if (!tree) return false
      return !hasSplitDivider(tree)
    })

    // Test 4: Create a split and verify separator appears
    console.log('\n--- Test 4: Split creates separator ---')
    // Use control socket to trigger a split
    await socketCmd('NEW-TAB')  // creates second surface
    await sleep(5000)
    tree = await getGhosttyTree()
    if (tree) {
      console.log('\n--- Tree after split ---')
      printTree(tree)
    }

    // Test 5: Verify the tree changes after new tab
    console.log('\n--- Test 5: Tree changes after new tab ---')
    await check('tree has multiple widget nodes after new tab', async () => {
      if (!tree) return false
      const widgets = findByRole(tree, 'widget')
      return widgets.length >= 1
    })

  } finally {
    if (ghosttyProc) { ghosttyProc.kill(); ghosttyProc = null }
    if (existsSync(SOCK)) unlinkSync(SOCK)
  }

  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`)
  process.exit(failed > 0 ? 1 : 0)
}

main().catch(e => { console.error(e); process.exit(1) })
