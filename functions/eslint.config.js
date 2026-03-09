import js from '@eslint/js';
import tsPlugin from '@typescript-eslint/eslint-plugin';
import tsParser from '@typescript-eslint/parser';

export default [
  { ignores: ['lib/**', 'node_modules/**', 'check-ses-status.js', 'enable_connect.js'] },
  js.configs.recommended,
  {
    files: ['**/*.ts'],
    plugins: { '@typescript-eslint': tsPlugin },
    languageOptions: {
      parser: tsParser,
      parserOptions: { ecmaVersion: 'latest', sourceType: 'module' },
      globals: {
        console: 'readonly',
        process: 'readonly',
        Buffer: 'readonly',
        __dirname: 'readonly',
        __filename: 'readonly',
        module: 'readonly',
        require: 'readonly',
        exports: 'writable',
        URL: 'readonly',
        URLSearchParams: 'readonly',
        Response: 'readonly',
        fetch: 'readonly',
      },
    },
    rules: {
      'no-var': 'error',
      'prefer-const': ['warn', { destructuring: 'all' }],
      'quotes': ['warn', 'single', { allowTemplateLiterals: true }],
      'semi': 'warn',
      'comma-dangle': ['warn', 'always-multiline'],
      'max-len': ['warn', { code: 140, ignoreUrls: true }],
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': ['warn', { argsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' }],
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/explicit-function-return-type': 'off',
      '@typescript-eslint/no-require-imports': 'off',
      'no-useless-escape': 'warn',
    },
  },
];
