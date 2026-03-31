/**
 * Tab management tests via control socket.
 *
 * Tests NEW-TAB, GOTO-TAB, CLOSE-TAB commands.
 * Run: cd test/ui && bun run specs/gtk/tabs.spec.ts
 */
import { existsSync, unlinkSync } from 'fs'
import { resolve } from 'path'
import net from 'net'

const GHOSTTY = process.env.GHOSTTY ?? resolve(__dirname, '../../../../zig-out/bin/ghostty')
const SOCK = `/tmp/ghostty-tab-test-${process.pid}.sock`

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

function tabCount(resp: string): number {
  try {
    return JSON.parse(resp).length
  } catch { return 0 }
}

async function main() {
  console.log('=== Ghostty Tab Tests (Control Socket) ===')
  console.log(`Binary: ${GHOSTTY}`)

  try {
    if (existsSync(SOCK)) unlinkSync(SOCK)
    ghosttyProc = Bun.spawn([GHOSTTY, `--control-socket=${SOCK}`, '--status-bar=true'], {
      stdout: 'ignore', stderr: 'ignore',
    })
    for (let i = 0; i < 30; i++) { if (existsSync(SOCK)) break; await sleep(200) }
    if (!existsSync(SOCK)) throw new Error('Socket did not appear')
    await sleep(2000)

    // Test 1: Initial state
    console.log('\n--- Test 1: Initial state ---')
    await check('starts with 1 tab', async () => {
      return tabCount(await socketCmd('LIST-TABS')) === 1
    })

    // Test 2: NEW-TAB
    console.log('\n--- Test 2: NEW-TAB ---')
    await check('NEW-TAB returns OK', async () => {
      return (await socketCmd('NEW-TAB')) === 'OK'
    })
    await sleep(5000) // Wait for surface init (GLArea resize is async)
    await check('now has 2 tabs', async () => {
      return tabCount(await socketCmd('LIST-TABS')) === 2
    })

    // Test 3: GOTO-TAB previous
    console.log('\n--- Test 3: GOTO-TAB previous ---')
    await check('GOTO-TAB previous returns OK', async () => {
      return (await socketCmd('GOTO-TAB previous')) === 'OK'
    })
    await check('tab 0 is now active', async () => {
      const tabs = JSON.parse(await socketCmd('LIST-TABS'))
      return tabs[0].active === true
    })

    // Test 4: GOTO-TAB next
    console.log('\n--- Test 4: GOTO-TAB next ---')
    await check('GOTO-TAB next returns OK', async () => {
      return (await socketCmd('GOTO-TAB next')) === 'OK'
    })
    await check('tab 1 is now active', async () => {
      const tabs = JSON.parse(await socketCmd('LIST-TABS'))
      return tabs[1].active === true
    })

    // Test 5: GOTO-TAB by index
    console.log('\n--- Test 5: GOTO-TAB by index ---')
    await check('GOTO-TAB 0 returns OK', async () => {
      return (await socketCmd('GOTO-TAB 0')) === 'OK'
    })

    // Test 6: CLOSE-TAB (close the second tab, back to 1)
    console.log('\n--- Test 6: CLOSE-TAB ---')
    await socketCmd('GOTO-TAB 1')
    await sleep(500)
    await check('CLOSE-TAB returns OK', async () => {
      return (await socketCmd('CLOSE-TAB')) === 'OK'
    })
    await sleep(1000)
    await check('back to 1 tab', async () => {
      return tabCount(await socketCmd('LIST-TABS')) === 1
    })

  } finally {
    if (ghosttyProc) { ghosttyProc.kill(); ghosttyProc = null }
    if (existsSync(SOCK)) unlinkSync(SOCK)
  }

  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`)
  process.exit(failed > 0 ? 1 : 0)
}

main().catch(e => { console.error(e); process.exit(1) })
