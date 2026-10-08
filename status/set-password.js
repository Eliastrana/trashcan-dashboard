// Sets (or changes) the status page password. Run it on the trashcan:  node set-password.js
// Stores a salted scrypt hash plus a fresh cookie-signing key (so changing it logs everyone out).
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const DATA = process.env.DATA_DIR || path.join(path.dirname(fileURLToPath(import.meta.url)), 'data');
fs.mkdirSync(DATA, { recursive: true, mode: 0o700 });

function ask(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl._writeToOutput = (s) => { if (s.includes(prompt)) process.stdout.write(s); };   // hide what is typed
    rl.question(prompt, (answer) => { rl.close(); process.stdout.write('\n'); resolve(answer); });
  });
}

const password = await ask('Nytt passord (minst 12 tegn): ');
if (password.length < 12) { console.error('For kort. Ingen endring gjort.'); process.exit(1); }
if (password !== await ask('Gjenta passordet: ')) { console.error('Passordene er ikke like. Ingen endring gjort.'); process.exit(1); }

const salt = crypto.randomBytes(16);
const hash = crypto.scryptSync(password, salt, 64);
const file = path.join(DATA, 'password.json');
fs.writeFileSync(file, JSON.stringify({ salt: salt.toString('base64'), hash: hash.toString('base64'), secret: crypto.randomBytes(32).toString('base64') }), { mode: 0o600 });
console.log('Passordet er lagret i', file);
