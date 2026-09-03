import js from '@eslint/js'
import globals from 'globals'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  { ignores: ['dist/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2022,
      globals: { ...globals.browser, ...globals.node },
    },
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    },
  },
  {
    // Solid assigns `let node: HTMLElement | undefined` through `ref={node}`
    // in compiled output, which ESLint 10's recommended `no-unassigned-vars`
    // cannot see. The rule stays on for plain .ts files.
    files: ['**/*.tsx'],
    rules: {
      'no-unassigned-vars': 'off',
    },
  },
)
