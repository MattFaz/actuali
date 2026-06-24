// scripts/gen-encryption-fixture.mjs
// Generates a known-good encryption fixture mirroring Actual's E2EE key derivation.
// Run: node scripts/gen-encryption-fixture.mjs > Actuali/ActualiTests/Fixtures/encryption-key-fixture.json
import crypto from 'node:crypto';

const password = 'correct horse battery staple';
const keyId = '11111111-1111-1111-1111-111111111111';
const salt = crypto.randomBytes(32).toString('base64');

// CRITICAL: salt fed to PBKDF2 is the UTF-8 bytes of the base64 string (Buffer.from(salt)).
const derivedKey = crypto.pbkdf2Sync(
  Buffer.from(password, 'utf8'),
  Buffer.from(salt),          // <-- utf8 bytes of the base64 string, NOT base64-decoded
  10000,
  32,
  'sha512',
);

// Build the "test" message the way Actual does: encrypt a random payload, strip the auth tag.
const iv = crypto.randomBytes(12);
const cipher = crypto.createCipheriv('aes-256-gcm', derivedKey, iv);
const testPlaintext = crypto.randomBytes(32);
const ct = Buffer.concat([cipher.update(testPlaintext), cipher.final()]);
const authTag = cipher.getAuthTag();

const fixture = {
  password,
  wrongPassword: 'incorrect password',
  salt,
  keyId,
  derivedKeyBase64: derivedKey.toString('base64'),
  test: JSON.stringify({
    value: ct.toString('base64'),
    meta: {
      keyId,
      algorithm: 'aes-256-gcm',
      iv: iv.toString('base64'),
      authTag: authTag.toString('base64'),
    },
  }),
};
process.stdout.write(JSON.stringify(fixture, null, 2) + '\n');
