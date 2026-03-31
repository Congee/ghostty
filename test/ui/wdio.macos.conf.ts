import type { Options } from '@wdio/types'
import path from 'path'

const GHOSTTY_APP = process.env.GHOSTTY_APP
  ?? path.resolve(__dirname, '../../macos/build/Debug/Ghostty.app')

export const config: Options.Testrunner = {
  runner: 'local',
  autoCompileOpts: {
    tsNodeOpts: { project: './tsconfig.json' },
  },

  specs: ['./specs/macos/**/*.spec.ts'],

  capabilities: [{
    platformName: 'mac',
    'appium:automationName': 'mac2',
    'appium:bundleId': 'com.mitchellh.ghostty',
    'appium:app': GHOSTTY_APP,
    'appium:newCommandTimeout': 30,
  }],

  framework: 'mocha',
  reporters: ['spec'],
  mochaOpts: {
    ui: 'bdd',
    timeout: 30000,
  },

  port: 4723,
  path: '/',
}
