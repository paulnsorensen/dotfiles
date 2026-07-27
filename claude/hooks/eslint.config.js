// Flat config for the Claude Code hook scripts. Replaces the eslint 8 CLI
// flags (--no-eslintrc / --env node / --env es2020 / --rule) that eslint 10
// removed. The hooks are CommonJS Node scripts.
module.exports = [
    {
        languageOptions: {
            ecmaVersion: 2021,
            sourceType: 'commonjs',
            globals: {
                process: 'readonly',
                console: 'readonly',
                __dirname: 'readonly',
                __filename: 'readonly',
            },
        },
        rules: {
            'no-undef': 'error',
            'no-unused-vars': 'warn',
            'no-redeclare': 'error',
        },
    },
];
