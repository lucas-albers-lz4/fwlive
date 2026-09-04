#!/usr/bin/env node
/**
 * Static server for mocked LuCI view harness (Tier 2 / #240 Wave B2).
 *
 * Loopback-only. Serves only allowlisted prefixes under fixed roots (#249 / CodeQL).
 *
 *   node scripts/serve-view-harness.mjs
 *   FWLIVE_HARNESS_PORT=8765 node scripts/serve-view-harness.mjs
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.FWLIVE_HARNESS_PORT || 8765);
const HOST_RAW = process.env.FWLIVE_HARNESS_HOST || '127.0.0.1';

const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost']);

/** Fixed roots — URL must match prefix; path segments validated before join. */
const ALLOWED_ROOTS = [
	{
		prefix: '/tests/fixtures/',
		root: path.join(ROOT, 'tests', 'fixtures')
	},
	{
		prefix: '/openwrt-feed/luci-app-fwlive/htdocs/luci-static/',
		root: path.join(ROOT, 'openwrt-feed', 'luci-app-fwlive', 'htdocs', 'luci-static')
	}
];

const MIME = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.png': 'image/png',
	'.svg': 'image/svg+xml'
};

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

function isSafeSegment(seg) {
	return seg.length > 0 && seg !== '.' && seg !== '..' &&
		seg !== '.git' && /^[a-zA-Z0-9._-]+$/.test(seg);
}

function isDeniedGitPath(rootReal, real) {
	const rel = path.relative(rootReal, real);
	if (!rel || rel.startsWith('..'))
		return true;
	return rel.split(path.sep).includes('.git');
}

/** Map request URL to a real file under an allowlisted root, or null. */
function resolveAllowedFile(urlPath) {
	let pathname;
	try {
		pathname = decodeURIComponent(String(urlPath || '').split('?')[0]);
	} catch (e) {
		return null;
	}

	if (pathname === '/' || pathname === '')
		pathname = '/tests/fixtures/luci-view-harness.html';

	for (const entry of ALLOWED_ROOTS) {
		if (!pathname.startsWith(entry.prefix))
			continue;

		const suffix = pathname.slice(entry.prefix.length);
		if (!suffix)
			return null;

		const segments = suffix.split('/').filter(Boolean);
		if (!segments.length || !segments.every(isSafeSegment))
			return null;

		let rootReal;
		try {
			rootReal = fs.realpathSync(entry.root);
		} catch (e) {
			return null;
		}

		const abs = path.join(rootReal, ...segments);
		let real;
		try {
			if (!fs.existsSync(abs))
				return null;
			real = fs.realpathSync(abs);
		} catch (e) {
			return null;
		}

		if (!real.startsWith(rootReal + path.sep) && real !== rootReal)
			return null;
		if (isDeniedGitPath(rootReal, real))
			return null;

		return real;
	}

	return null;
}

const server = http.createServer((req, res) => {
	try {
		const abs = resolveAllowedFile(req.url);
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
