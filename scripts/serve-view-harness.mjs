#!/usr/bin/env node
/**
 * Static server for mocked LuCI view harness (Tier 2 / #240 Wave B2).
 *
 * Loopback-only by default. Refuses path escape via `..`, symlinks, or `.git`.
 *
 *   node scripts/serve-view-harness.mjs
 *   FWLIVE_HARNESS_PORT=8765 node scripts/serve-view-harness.mjs
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT_REAL = fs.realpathSync(ROOT);
const PORT = Number(process.env.FWLIVE_HARNESS_PORT || 8765);
const HOST_RAW = process.env.FWLIVE_HARNESS_HOST || '127.0.0.1';

const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost']);

function assertLoopbackHost(host) {
	const h = String(host || '').toLowerCase();
	if (!LOOPBACK.has(h)) {
		console.error(
			`serve-view-harness: refusing non-loopback bind "${host}" ` +
			'(set FWLIVE_HARNESS_HOST to 127.0.0.1 or ::1)'
		);
		process.exit(1);
	}
	return host === 'localhost' ? '127.0.0.1' : host;
}

const HOST = assertLoopbackHost(HOST_RAW);

const MIME = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.png': 'image/png',
	'.svg': 'image/svg+xml'
};

function isDeniedGitPath(real) {
	const rel = path.relative(ROOT_REAL, real);
	if (!rel || rel.startsWith('..'))
		return true;
	return rel.split(path.sep).includes('.git');
}

/** Resolve URL to a real file under ROOT; null if missing, escaped, or denied. */
function safePath(urlPath) {
	let decoded;
	try {
		decoded = decodeURIComponent((urlPath || '').split('?')[0]);
	} catch (e) {
		return null;
	}

	const rel = decoded.replace(/^\/+/, '');
	if (!rel || rel.split(/[/\\]/).includes('..'))
		return null;
	if (rel === '.git' || rel.startsWith('.git/') || rel.startsWith('.git' + path.sep))
		return null;

	const abs = path.resolve(ROOT, rel);
	if (!abs.startsWith(ROOT + path.sep) && abs !== ROOT)
		return null;

	let real;
	try {
		if (!fs.existsSync(abs))
			return null;
		real = fs.realpathSync(abs);
	} catch (e) {
		return null;
	}

	if (!real.startsWith(ROOT_REAL + path.sep) && real !== ROOT_REAL)
		return null;
	if (isDeniedGitPath(real))
		return null;

	return real;
}

const server = http.createServer((req, res) => {
	try {
		let urlPath = req.url || '/';
		if (urlPath === '/')
			urlPath = '/tests/fixtures/luci-view-harness.html';

		const abs = safePath(urlPath);
		if (!abs) {
			res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
			res.end('not found');
			return;
		}

		let st;
		try {
			st = fs.statSync(abs);
		} catch (e) {
			res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
			res.end('not found');
			return;
		}
		if (st.isDirectory()) {
			res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
			res.end('not found');
			return;
		}

		const ext = path.extname(abs);
		res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
		const stream = fs.createReadStream(abs);
		stream.on('error', () => {
			if (!res.headersSent)
				res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
			res.end('read error');
		});
		stream.pipe(res);
	} catch (e) {
		if (!res.headersSent)
			res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
		res.end('server error');
	}
});

server.listen(PORT, HOST, () => {
	process.stdout.write(`fwlive view harness http://${HOST}:${PORT}/\n`);
});

function shutdown() {
	server.close(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
