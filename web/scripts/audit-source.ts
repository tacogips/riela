const sourceRoot = new URL('../src/', import.meta.url)
const banned = [
  /from\s+['"][^'"]*(fixture|mock)[^'"]*['"]/i,
  /globalThis\.fetch\s*=/,
  /window\.fetch\s*=/,
  /sampleResponse/i,
]

async function visit(url: URL): Promise<string[]> {
  const results: string[] = []
  for await (const entry of new Bun.Glob('**/*.{ts,tsx}').scan({ cwd: url.pathname, absolute: true })) {
    const source = await Bun.file(entry).text()
    for (const pattern of banned) {
      if (pattern.test(source)) results.push(`${entry}: banned production fixture pattern ${pattern}`)
    }
  }
  return results
}

const findings = await visit(sourceRoot)
if (findings.length > 0) {
  console.error(findings.join('\n'))
  process.exit(1)
}
console.log('Production source audit passed')
