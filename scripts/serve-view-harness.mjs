#!/usr/bin/env node
/**
 * Static server for mocked LuCI view harness (Tier 2 / #240 Wave B2).
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
const HOST = process.env.FWLIVE_HARNESS_HOST || '127.0.0.1';

const MIME = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.png': 'image/png',
	'.svg': 'image/svg+xml'
};

function safePath(urlPath) {
	const decoded = decodeURIComponent(urlPath.split('?')[0]);
	const rel = decoded.replace(/^\/+/, '');
	const abs = path.resolve(ROOT, rel);
	if (!abs.startsWith(ROOT + path.sep) && abs !== ROOT)
		return null;
	return abs;
}

const server = http.createServer((req, res) => {
	let urlPath = req.url || '/';
	if (urlPath === '/')
		urlPath = '/tests/fixtures/luci-view-harness.html';

	const abs = safePath(urlPath);
	if (!abs || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
		res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
		res.end('not found');
		return;
	}

	const ext = path.extname(abs);
	res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
	fs.createReadStream(abs).pipe(res);
});

server.listen(PORT, HOST, () => {
	process.stdout.write(`fwlive view harness http://${HOST}:${PORT}/\n`);
});

function shutdown() {
	server.close(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
