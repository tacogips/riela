import { describe, expect, test } from 'bun:test'
import {
  OPS_ADDON_STYLE,
  OPS_AGENT_STYLE,
  OPS_HUB_COLORS,
  OPS_MANAGER_STYLE,
  kindStyle,
  statusStyle,
} from './palette'

const neutralColors = new Set(['#ffffff', '#f5f5f5', '#e5e5e5', '#d4d4d4', '#cccccc', '#a3a3a3', '#8a8a8a', '#737373'])

describe('monochrome command deck palette', () => {
  test('uses only neutral colors for workflow kinds and hubs', () => {
    const kinds = [
      OPS_AGENT_STYLE,
      OPS_ADDON_STYLE,
      OPS_MANAGER_STYLE,
      kindStyle('task', null, null),
      kindStyle('branch-judge', null, null),
      kindStyle('loop-judge', null, null),
      kindStyle('input', null, null),
      kindStyle('output', null, null),
    ]
    expect(kinds.every(style => neutralColors.has(style.color))).toBe(true)
    expect(OPS_HUB_COLORS.every(color => neutralColors.has(color))).toBe(true)
  })

  test('reserves color for active completion and failure status', () => {
    expect(statusStyle('created').color).toBe('#d4d4d4')
    expect(statusStyle('skipped').color).toBe('#a3a3a3')
    expect(statusStyle(undefined).color).toBe('#737373')
    expect(statusStyle('running').color).toBe('#f2d268')
    expect(statusStyle('completed').color).toBe('#45d0a3')
    expect(statusStyle('failed').color).toBe('#f4737f')
  })

  test('keeps structural UI and the execution graph monochrome', async () => {
    const theme = await Bun.file(new URL('../monochrome-theme.css', import.meta.url)).text()
    for (const selector of ['.skip-link', '.server-card', '.dot', '.editor-port.output']) {
      expect(theme).toContain(selector)
    }

    const graph = await Bun.file(new URL('../views/RunExecutionGraph.tsx', import.meta.url)).text()
    for (const legacyColor of ['#65bcd2', '#142938', '#45667d', '#dfebf3', '#9eb3c3']) {
      expect(graph).not.toContain(legacyColor)
    }
  })
})
