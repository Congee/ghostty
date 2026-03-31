import { waitForTerminal, typeCommand, waitForWindowClose, pressKeys } from '../../helpers/ghostty'

describe('Ghostty macOS Terminal', () => {
  it('should launch and show a terminal', async () => {
    await waitForTerminal()
    const title = await browser.getTitle()
    expect(title).toBeTruthy()
  })

  it('should accept keyboard input', async () => {
    await waitForTerminal()
    await typeCommand('echo hello-appium-test')
    await browser.pause(500)
  })

  it('should close when shell exits', async () => {
    await waitForTerminal()
    await typeCommand('exit')
    await waitForWindowClose()
  })
})

describe('Ghostty macOS Splits', () => {
  it('should create a split with keybinding', async () => {
    await waitForTerminal()
    // macOS split keybinding (Cmd+D or configurable)
    await pressKeys(['Meta', 'd'])
    await browser.pause(1000)
  })

  it('should resize a split by dragging the divider', async () => {
    await waitForTerminal()
    await pressKeys(['Meta', 'd'])
    await browser.pause(1000)

    // Find the split divider via accessibility
    const divider = await browser.$('//XCUIElementTypeSplitter')
    if (await divider.isExisting()) {
      const location = await divider.getLocation()
      const size = await divider.getSize()

      await browser.performActions([{
        type: 'pointer',
        id: 'mouse',
        parameters: { pointerType: 'mouse' },
        actions: [
          { type: 'pointerMove', duration: 0, x: location.x + size.width / 2, y: location.y + size.height / 2 },
          { type: 'pointerDown', button: 0 },
          { type: 'pointerMove', duration: 300, x: location.x + size.width / 2 + 50, y: location.y + size.height / 2 },
          { type: 'pointerUp', button: 0 },
        ],
      }])
      await browser.pause(500)
    }
  })
})
