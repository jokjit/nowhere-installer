// Exercise the official binary exclusively on loopback; no system services.
// node tests/upstream-smoke.mjs /path/to/nowhere [/path/to/openssl]
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import net from 'node:net';
import dgram from 'node:dgram';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const binary = process.argv[2];
const openssl = process.argv[3] || 'openssl';
if (!binary) throw new Error('Usage: node tests/upstream-smoke.mjs BINARY [OPENSSL]');
const temp = await mkdtemp(path.join(os.tmpdir(), 'nowhere-smoke-'));
const children = new Set();
const encode = value => encodeURIComponent(value).replace(/[!'()*]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
const key = 'local-test-密钥@:&+%';
const user = 'test@用户:+';
const pass = 'test-password:@&+%';
let origin;

async function freePort(withUdp = false) {
  for (let attempt = 0; attempt < 10; attempt++) {
    const server = net.createServer();
    await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
    const port = server.address().port;
    let udp;
    try {
      if (withUdp) {
        udp = dgram.createSocket('udp4');
        await new Promise((resolve, reject) => udp.once('error', reject).bind(port, '127.0.0.1', resolve));
      }
      return port;
    } catch {
      // Retry a TCP-selected port already occupied by an unrelated UDP listener.
    } finally {
      if (udp) udp.close();
      await new Promise(resolve => server.close(resolve));
    }
  }
  throw new Error('Unable to allocate a loopback port');
}

function launch(url) {
  const child = spawn(binary, [url], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  child.output = '';
  child.on('error', error => { child.launchError = error; });
  for (const stream of [child.stdout, child.stderr]) {
    stream.on('data', chunk => { child.output = (child.output + chunk).slice(-16384); });
  }
  children.add(child);
  return child;
}

async function stop(child) {
  if (child.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit');
    child.kill('SIGTERM');
    let timer;
    await Promise.race([
      exited,
      new Promise(resolve => { timer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 7000); }),
    ]);
    clearTimeout(timer);
    if (child.exitCode === null && child.signalCode === null) await exited;
  }
  children.delete(child);
}

async function waitPort(child, port) {
  for (let i = 0; i < 100; i++) {
    if (child.launchError) throw child.launchError;
    if (child.exitCode !== null) throw new Error(`Nowhere exited: ${child.output}`);
    const ready = await new Promise(resolve => {
      const socket = net.createConnection({ host: '127.0.0.1', port });
      socket.once('connect', () => { socket.destroy(); resolve(true); });
      socket.once('error', () => { socket.destroy(); resolve(false); });
    });
    if (ready) return;
    await delay(100);
  }
  throw new Error(`Listener timeout: ${child.output}`);
}

function reader(socket) {
  let data = Buffer.alloc(0);
  let failure;
  let wake;
  socket.on('data', chunk => { data = Buffer.concat([data, chunk]); wake?.(); });
  socket.on('error', error => { failure = error; wake?.(); });
  socket.on('close', () => { failure ??= new Error('Socket closed'); wake?.(); });
  socket.setTimeout(15000, () => socket.destroy(new Error('SOCKS test timeout')));
  return async size => {
    while (data.length < size) {
      if (failure) throw failure;
      await new Promise(resolve => { wake = resolve; });
      wake = null;
    }
    const result = data.subarray(0, size);
    data = data.subarray(size);
    return result;
  };
}

async function request(socksPort, targetPort, password = pass, expectAuthFailure = false, expectPinFailure = false) {
  const socket = net.createConnection({ host: '127.0.0.1', port: socksPort });
  const read = reader(socket);
  try {
    await once(socket, 'connect');
    socket.write(Buffer.from([5, 1, 2]));
    assert.deepEqual(await read(2), Buffer.from([5, 2]));
    const ub = Buffer.from(user), pb = Buffer.from(password);
    socket.write(Buffer.concat([Buffer.from([1, ub.length]), ub, Buffer.from([pb.length]), pb]));
    const auth = await read(2);
    if (expectAuthFailure) { assert.notEqual(auth[1], 0); return; }
    assert.equal(auth[1], 0, 'SOCKS5 credentials with reserved characters must work');
    socket.write(Buffer.from([5, 1, 0, 1, 127, 0, 0, 1, targetPort >> 8, targetPort & 255]));
    const response = await read(4);
    if (expectPinFailure) { assert.notEqual(response[1], 0, 'Wrong certificate pin must be rejected'); return; }
    assert.equal(response[1], 0, 'SOCKS5 target connection failed');
    if (response[3] === 1) await read(6);
    else if (response[3] === 4) await read(18);
    else await read((await read(1))[0] + 2);
    socket.write('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n');
    const expected = Buffer.from('HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnowhere-test');
    assert.deepEqual(await read(expected.length), expected);
  } finally {
    socket.destroy();
  }
}

try {
  console.log(execFileSync(binary, ['--version'], { encoding: 'utf8', windowsHide: true }).trim());
  const cert = path.join(temp, 'cert.pem'), privateKey = path.join(temp, 'key.pem');
  execFileSync(openssl, ['req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes', '-days', '1',
    '-subj', '/CN=nowhere', '-keyout', privateKey, '-out', cert], { windowsHide: true, stdio: 'pipe' });
  const pin = new X509Certificate(await readFile(cert)).fingerprint256.replaceAll(':', '').toLowerCase();
  origin = net.createServer(socket => {
    socket.once('data', () => socket.end('HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnowhere-test'));
    socket.on('error', () => {});
  });
  await new Promise(resolve => origin.listen(0, '127.0.0.1', resolve));
  const originPort = origin.address().port;
  const portalPort = await freePort(true);
  const portal = launch(`portal://${encode(key)}@127.0.0.1:${portalPort}?tls=2&crt=${encode(cert)}&key=${encode(privateKey)}&log=info`);
  await waitPort(portal, portalPort);
  for (const [up, down] of [['tcp', 'tcp'], ['tcp', 'udp'], ['udp', 'tcp'], ['udp', 'udp'], ['mix', 'mix']]) {
    const socksPort = await freePort();
    const vector = launch(`vector://${encode(key)}@127.0.0.1:${portalPort}?up=${up}&down=${down}&pin=${pin}&socks=${encode(user)}:${encode(pass)}@127.0.0.1:${socksPort}`);
    try {
      await waitPort(vector, socksPort);
      await request(socksPort, originPort);
      await request(socksPort, originPort, 'incorrect-password', true);
      console.log(`PASS ${up}/${down}: pinned TLS + SOCKS5 credentials + HTTP relay`);
    } catch (error) {
      throw new Error(`${error.message}\nVector: ${vector.output}\nPortal: ${portal.output}`, { cause: error });
    } finally { await stop(vector); }
  }
  const socksPort = await freePort();
  const wrongPin = launch(`vector://${encode(key)}@127.0.0.1:${portalPort}?up=tcp&down=tcp&pin=${'0'.repeat(64)}&socks=${encode(user)}:${encode(pass)}@127.0.0.1:${socksPort}`);
  await waitPort(wrongPin, socksPort);
  await request(socksPort, originPort, pass, false, true);
  console.log('PASS wrong certificate pin is rejected');
} finally {
  await Promise.all([...children].map(stop));
  if (origin) await new Promise(resolve => origin.close(resolve));
  await rm(temp, { recursive: true, force: true });
}
