/**
 * GTK UI tests for Ghostty.
 *
 * Uses:
 * - wtype (Wayland keystroke injection)
 * - AT-SPI2 via busctl for accessibility tree queries
 * - Ghostty control socket for state verification
 *
 * Requirements:
 * - Wayland session (wtype only works on Wayland)
 * - wtype installed: nix run nixpkgs#wtype
 * - Ghostty built: zig build -Dapp-runtime=gtk
 *
 * Run: cd test/ui && bun run specs/gtk/terminal.spec.ts
 */

import { $ } from 'bun'
import { existsSync, unlinkSync } from 'fs'
import { resolve } from 'path'
import net from 'net'

const GHOSTTY = process.env.GHOSTTY ?? resolve(__dirname, '../../../../zig-out/bin/ghostty')
const SOCK = `/tmp/ghostty-ui-test-${process.pid}.sock`

let ghosttyProc: ReturnType<typeof Bun.spawn> | null = null
let passed = 0
let failed = 0

// --- Helpers ---

function socketCmd(msg: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(SOCK, () => {
      client.write(msg + '\n')
    })
    let data = ''
    client.on('data', (chunk) => { data += chunk.toString() })
    client.on('end', () => resolve(data.trim()))
    client.setTimeout(3000)
    client.on('timeout', () => { client.destroy(); reject(new Error('timeout')) })
    client.on('error', reject)
  })
}

async function activateGhostty() {
  // Focus Ghostty's window via wlrctl (wlroots compositor control)
  await $`wlrctl window focus ghostty`.quiet().catch(() => {})
  await sleep(200)
}

async function wtype(text: string) {
  await activateGhostty()
  await $`wtype ${text}`.quiet()
}

async function wtypeKey(key: string) {
  await activateGhostty()
  await $`wtype -k ${key}`.quiet()
}

async function sleep(ms: number) {
  return new Promise(r => setTimeout(r, ms))
}

function ok(desc: string) { passed++; console.log(`  PASS: ${desc}`) }
function fail(desc: string, detail = '') {
  failed++
  console.log(`  FAIL: ${desc}${detail ? ` (${detail})` : ''}`)
}

async function check(desc: string, fn: () => Promise<boolean>) {
  try {
    if (await fn()) ok(desc)
    else fail(desc)
  } catch (e: any) {
    fail(desc, e.message)
  }
}

// --- Setup ---

async function startGhostty() {
  if (existsSync(SOCK)) unlinkSync(SOCK)
  ghosttyProc = Bun.spawn([GHOSTTY, `--control-socket=${SOCK}`, '--status-bar=true'], {
    stdout: 'ignore',
    stderr: 'ignore',
  })
  // Wait for socket
  for (let i = 0; i < 30; i++) {
    if (existsSync(SOCK)) break
    await sleep(200)
  }
  if (!existsSync(SOCK)) throw new Error('Control socket did not appear')
  // Wait for surface to initialize
  await sleep(2000)
}

function stopGhostty() {
  if (ghosttyProc) {
    ghosttyProc.kill()
    ghosttyProc = null
  }
  if (existsSync(SOCK)) unlinkSync(SOCK)
}

// --- Tests ---

async function main() {
  console.log('=== Ghostty GTK UI Tests ===')
  console.log(`Binary: ${GHOSTTY}`)
  console.log(`Socket: ${SOCK}`)

  try {
    // Test 1: Launch and verify control socket
    console.log('\n--- Test 1: Launch ---')
    await startGhostty()
    await check('Ghostty launches and socket responds', async () => {
      const resp = await socketCmd('PING')
      return resp === 'PONG'
    })

    // Test 2: Type into terminal via wtype
    console.log('\n--- Test 2: Keystroke injection ---')
    await check('wtype sends keystrokes', async () => {
      await wtype('echo ui-test-ok')
      await wtypeKey('Return')
      await sleep(500)
      return true // If wtype didn't error, keystrokes were sent
    })

    // Test 3: Verify terminal dimensions via control socket
    console.log('\n--- Test 3: Terminal dimensions ---')
    await check('GET-DIMENSIONS returns valid size', async () => {
      const resp = await socketCmd('GET-DIMENSIONS')
      const dims = JSON.parse(resp)
      return dims.rows > 0 && dims.cols > 0
    })

    // Test 4: Tab operations via control socket
    console.log('\n--- Test 4: Tab list ---')
    await check('LIST-TABS returns JSON', async () => {
      const resp = await socketCmd('LIST-TABS')
      return resp.includes('"index"')
    })

    // Test 5: Shell exit closes window
    // Launch a separate ghostty with a command that exits immediately.
    // The window should close automatically (wait_after_command = false).
    console.log('\n--- Test 5: Shell exit closes window ---')
    stopGhostty()
    await check('shell exit closes ghostty', async () => {
      const proc = Bun.spawn([GHOSTTY, '-e', '/bin/sh', '-c', 'sleep 1; exit 0'], {
        stdout: 'ignore',
        stderr: 'ignore',
      })
      // Wait for the process to exit (shell exits after 1s, then ghostty closes)
      const start = Date.now()
      while (Date.now() - start < 8000) {
        try {
          process.kill(proc.pid, 0)
          await sleep(200)
        } catch {
          return true // Exited
        }
      }
      proc.kill()
      return false // Didn't exit
    })
  } finally {
    stopGhostty()
  }

  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`)
  process.exit(failed > 0 ? 1 : 0)
}

main().catch(e => {
  console.error(e)
  stopGhostty()
  process.exit(1)
})
