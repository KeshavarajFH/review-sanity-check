#!/usr/bin/env node
// Reports references on changed lines that resolve to nothing at runtime:
//   MISSING-EXPORT  import { name } from a repo module that does not export `name`
//   MISSING-KEY     X.KEY where X is an imported object literal (or LocalizedStrings table) without KEY
// Usage (from the root of a checkout of the branch tip):
//   node check-references.js <changed-lines-file> <file>...
// <changed-lines-file> holds "path:line" entries, as written by the review skill's Step 0.
// Uses the repo's own @babel/parser and reads module-resolver aliases from babel.config.js.
'use strict';

const fs = require('fs');
const path = require('path');

const root = process.cwd();
const parser = require(require.resolve('@babel/parser', { paths: [root] }));
const EXTENSIONS = ['', '.js', '.jsx', '.ts', '.tsx', '.json', '/index.js', '/index.ts', '/index.tsx'];

function parse(file) {
    const source = fs.readFileSync(file, 'utf8');
    const plugins = ['jsx', 'classProperties', 'optionalChaining', 'nullishCoalescingOperator', 'dynamicImport'];
    plugins.push(/\.tsx?$/.test(file) ? 'typescript' : 'flow');
    return parser.parse(source, { sourceType: 'module', errorRecovery: true, plugins });
}

function loadAliases() {
    const configFile = path.join(root, 'babel.config.js');
    if (!fs.existsSync(configFile)) return {};
    try {
        let config = require(configFile);
        if (typeof config === 'function') {
            const api = { cache: Object.assign(() => {}, { forever() {}, never() {}, using() {} }), env: () => false };
            config = config(api);
        }
        for (const plugin of config.plugins || []) {
            if (Array.isArray(plugin) && /module-resolver/.test(plugin[0])) return plugin[1].alias || {};
        }
    } catch (error) {
        process.stderr.write(`check-references: could not read aliases from babel.config.js (${error.message}); only relative imports are checked\n`);
    }
    return {};
}

const aliases = loadAliases();

function resolveModule(fromFile, source) {
    let base = null;
    if (source.startsWith('.')) {
        base = path.resolve(path.dirname(fromFile), source);
    } else {
        for (const [alias, target] of Object.entries(aliases)) {
            if (source === alias || source.startsWith(alias + '/')) {
                base = path.resolve(root, target + source.slice(alias.length));
                break;
            }
        }
    }
    if (!base) return null;
    const candidates = [];
    for (const ext of EXTENSIONS) candidates.push(base + ext);
    for (const ext of ['.js', '.ts', '.tsx']) candidates.push(base + '.native' + ext);
    return candidates.find((c) => fs.existsSync(c) && fs.statSync(c).isFile()) || null;
}

const moduleCache = new Map();

// Returns { names: Set|null, objects: Map<name, Set|null> } — null means "cannot tell".
function moduleExports(file) {
    if (moduleCache.has(file)) return moduleCache.get(file);
    const info = { names: new Set(), objects: new Map() };
    moduleCache.set(file, info);
    if (file.endsWith('.json')) {
        info.names = null;
        return info;
    }
    let ast;
    try {
        ast = parse(file);
    } catch {
        info.names = null;
        return info;
    }
    for (const node of ast.program.body) {
        if (node.type === 'ExportAllDeclaration') info.names = null;
        if (node.type !== 'ExportNamedDeclaration') continue;
        if (node.source) {
            node.specifiers.forEach((s) => info.names && info.names.add(s.exported.name));
            continue;
        }
        node.specifiers.forEach((s) => info.names && info.names.add(s.exported.name || s.exported.value));
        const decl = node.declaration;
        if (!decl) continue;
        if (decl.type === 'VariableDeclaration') {
            for (const d of decl.declarations) {
                if (d.id.type !== 'Identifier') continue;
                if (info.names) info.names.add(d.id.name);
                info.objects.set(d.id.name, objectKeys(file, d.init));
            }
        } else if (decl.id && info.names) {
            info.names.add(decl.id.name);
        }
    }
    return info;
}

// Methods react-localization adds to every LocalizedStrings instance; never reported as missing keys.
const LOCALIZED_STRINGS_METHODS = ['formatString', 'getLanguage', 'setLanguage', 'getInterfaceLanguage', 'getAvailableLanguages', 'getString', 'setContent'];

// Keys of an object literal, or of the first language table of `new LocalizedStrings({ en: ... })`.
function objectKeys(file, init) {
    if (!init) return null;
    if (init.type === 'NewExpression' && init.callee.name === 'LocalizedStrings' && init.arguments[0]?.type === 'ObjectExpression') {
        const first = init.arguments[0].properties[0];
        const keys = first ? objectKeys(file, first.value) : null;
        if (keys) LOCALIZED_STRINGS_METHODS.forEach((m) => keys.add(m));
        return keys;
    }
    if (init.type === 'ConditionalExpression') {
        // A per-brand or per-platform table: check against the default (else) branch.
        return objectKeys(file, init.alternate);
    }
    if (init.type === 'CallExpression' && init.callee.name === 'require' && init.arguments[0]?.type === 'StringLiteral') {
        const target = resolveModule(file, init.arguments[0].value);
        if (target && target.endsWith('.json')) return new Set(Object.keys(JSON.parse(fs.readFileSync(target, 'utf8'))));
        return null;
    }
    if (init.type !== 'ObjectExpression') return null;
    const keys = new Set();
    for (const p of init.properties) {
        if (p.type === 'SpreadElement' || p.computed) return null;
        keys.add(p.key.name || p.key.value);
    }
    return keys;
}

function walk(node, visit) {
    if (!node || typeof node.type !== 'string') return;
    visit(node);
    for (const key of Object.keys(node)) {
        if (key === 'loc' || key === 'start' || key === 'end') continue;
        const child = node[key];
        if (Array.isArray(child)) child.forEach((c) => walk(c, visit));
        else if (child && typeof child.type === 'string') walk(child, visit);
    }
}

function main() {
    const [changedFile, ...files] = process.argv.slice(2);
    if (!changedFile || files.length === 0) {
        process.stderr.write('usage: node check-references.js <changed-lines-file> <file>...\n');
        process.exit(2);
    }
    const changed = new Set(fs.readFileSync(changedFile, 'utf8').split('\n').filter(Boolean));
    const report = [];
    for (const rel of files) {
        const file = path.resolve(root, rel);
        if (!fs.existsSync(file)) continue;
        let ast;
        try {
            ast = parse(file);
        } catch (error) {
            process.stderr.write(`check-references: cannot parse ${rel}: ${error.message}\n`);
            continue;
        }
        const bindings = new Map();
        for (const node of ast.program.body) {
            if (node.type !== 'ImportDeclaration' || node.importKind === 'type') continue;
            const target = resolveModule(file, node.source.value);
            if (!target) continue;
            const exports = moduleExports(target);
            for (const s of node.specifiers) {
                if (s.type !== 'ImportSpecifier') continue;
                const name = s.imported.name || s.imported.value;
                bindings.set(s.local.name, { target, name });
                if (exports.names && !exports.names.has(name) && changed.has(`${rel}:${s.loc.start.line}`)) {
                    report.push(`MISSING-EXPORT ${rel}:${s.loc.start.line} ${name} is not exported by ${path.relative(root, target)}`);
                }
            }
        }
        walk(ast.program, (node) => {
            if (node.type !== 'MemberExpression' && node.type !== 'OptionalMemberExpression') return;
            if (node.computed || node.object.type !== 'Identifier' || node.property.type !== 'Identifier') return;
            const binding = bindings.get(node.object.name);
            if (!binding) return;
            const keys = moduleExports(binding.target).objects.get(binding.name);
            const line = node.loc.start.line;
            if (keys && !keys.has(node.property.name) && changed.has(`${rel}:${line}`)) {
                report.push(`MISSING-KEY ${rel}:${line} ${node.object.name}.${node.property.name} — no key ${node.property.name} in ${path.relative(root, binding.target)}`);
            }
        });
    }
    [...new Set(report)].forEach((r) => process.stdout.write(r + '\n'));
    process.exit(report.length ? 1 : 0);
}

main();
