#!/bin/bash
set -euo pipefail

APP_ROOT="${APP_ROOT:-/app}"
mkdir -p "$APP_ROOT/publisher"

cat > "$APP_ROOT/publisher/release-publisher.mjs" <<'NODE'
#!/usr/bin/env node
'use strict';

import duckdb from 'duckdb';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const APP_ROOT = path.resolve(SCRIPT_DIR, '..');

const GATEWAY_BASE_URL = process.env.GATEWAY_BASE_URL || 'http://127.0.0.1:7070';
const MANIFEST_PATH = process.env.BUILD_MANIFEST_PATH ||
  path.join(APP_ROOT, 'fixtures', 'build_manifest.csv');
const DB_PATH = process.env.RELEASES_DB_PATH ||
  path.join(APP_ROOT, 'releases.duckdb');
const CURRENT_KEY_PATH = process.env.CURRENT_SIGNING_KEY_PATH ||
  path.join(APP_ROOT, 'keys', 'current', 'current.key.pem');
const CURRENT_CERT_PATH = process.env.CURRENT_SIGNING_CERT_PATH ||
  path.join(APP_ROOT, 'keys', 'current', 'current.cert.pem');

function dbRun(conn, sql, ...params) {
  return new Promise((resolve, reject) => {
    conn.run(sql, ...params, (err) => err ? reject(err) : resolve());
  });
}

function dbAll(conn, sql, ...params) {
  return new Promise((resolve, reject) => {
    conn.all(sql, ...params, (err, rows) => err ? reject(err) : resolve(rows));
  });
}

function canonicalize(value) {
  if (Array.isArray(value)) {
    return '[' + value.map(canonicalize).join(',') + ']';
  }
  if (value !== null && typeof value === 'object') {
    return '{' + Object.keys(value).sort()
      .map((key) => JSON.stringify(key) + ':' + canonicalize(value[key]))
      .join(',') + '}';
  }
  return JSON.stringify(value);
}

function signDescriptor(descriptorBytes) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'fw-publisher-sign-'));
  const descriptorFile = path.join(scratch, 'descriptor.bin');

  try {
    fs.writeFileSync(descriptorFile, descriptorBytes);
    const signature = execFileSync('openssl', [
      'cms', '-sign',
      '-in', descriptorFile,
      '-signer', CURRENT_CERT_PATH,
      '-inkey', CURRENT_KEY_PATH,
      '-md', 'sha256',
      '-outform', 'PEM',
      '-binary',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    return signature.toString('utf8');
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

async function fetchCurrentSigningKey() {
  const response = await fetch(`${GATEWAY_BASE_URL}/v1/signing-key/current`);
  if (!response.ok) {
    throw new Error(`failed to fetch current signing key: HTTP ${response.status}`);
  }
  return response.json();
}

async function submitPublication(descriptor, signature, requestToken) {
  const response = await fetch(`${GATEWAY_BASE_URL}/v1/publications`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      descriptor,
      signature,
      request_token: requestToken,
    }),
  });

  const body = await response.json();
  if (!response.ok || body.error) {
    throw new Error(
      `gateway rejected publication for token ${requestToken}: ${body.error || response.status}`
    );
  }
  return body;
}

const RECONCILIATION_SQL = `
  WITH distinct_rows AS (
    SELECT DISTINCT * FROM manifest
  ),
  builds AS (
    SELECT * FROM distinct_rows
    WHERE record_type = 'BUILD'
  ),
  withdrawals AS (
    SELECT * FROM distinct_rows
    WHERE record_type = 'WITHDRAWAL'
  ),
  surviving AS (
    SELECT b.*
    FROM builds b
    WHERE NOT EXISTS (
      SELECT 1
      FROM withdrawals w
      WHERE w.supersedes_id = b.entry_id
    )
  )
  SELECT
    bundle_id,
    COUNT(*)::BIGINT AS artifact_count,
    SUM(size_bytes)::BIGINT AS total_bytes
  FROM surviving
  GROUP BY bundle_id
  HAVING COUNT(*) > 0
  ORDER BY bundle_id;
`;

async function main() {
  if (process.argv[2] !== '--report') {
    throw new Error('usage: node publisher/release-publisher.mjs --report');
  }

  const db = new duckdb.Database(DB_PATH);
  const conn = db.connect();

  try {
    await dbRun(conn, `
      CREATE TABLE IF NOT EXISTS publications (
        bundle_id       VARCHAR PRIMARY KEY,
        artifact_count  BIGINT NOT NULL,
        total_bytes     BIGINT NOT NULL,
        key_id          VARCHAR NOT NULL,
        descriptor      VARCHAR NOT NULL,
        signature       VARCHAR NOT NULL,
        request_token   VARCHAR NOT NULL UNIQUE,
        publication_id  VARCHAR NOT NULL,
        status          VARCHAR NOT NULL
      );
    `);

    await dbRun(
      conn,
      `CREATE OR REPLACE TABLE manifest AS
       SELECT * FROM read_csv_auto(?, header = true);`,
      MANIFEST_PATH
    );

    const bundles = await dbAll(conn, RECONCILIATION_SQL);
    const outputLines = [];
    let signingKey = null;

    for (const bundle of bundles) {
      const bundleId = String(bundle.bundle_id);
      const artifactCount = Number(bundle.artifact_count);
      const totalBytes = Number(bundle.total_bytes);
      const requestToken = `token-${bundleId}`;

      const existingRows = await dbAll(
        conn,
        `SELECT key_id, publication_id, request_token, status
           FROM publications
          WHERE bundle_id = ?
            AND request_token = ?
            AND status = 'PUBLISHED'`,
        bundleId,
        requestToken
      );

      if (existingRows.length > 0) {
        const existing = existingRows[0];
        outputLines.push(`BUNDLE ${bundleId} SIGNED KEY=${existing.key_id}`);
        outputLines.push(
          `BUNDLE ${bundleId} PUBLISHED RECEIPT=${existing.publication_id}` +
          ` TOKEN=${existing.request_token} STATUS=${existing.status}`
        );
        continue;
      }

      if (!signingKey) {
        signingKey = await fetchCurrentSigningKey();
        if (signingKey.status !== 'current') {
          throw new Error(`gateway signing key is not current: ${signingKey.status}`);
        }
      }

      const descriptor = canonicalize({
        artifact_count: artifactCount,
        bundle_id: bundleId,
        total_bytes: totalBytes,
      });
      const signature = signDescriptor(Buffer.from(descriptor, 'utf8'));

      const receipt = await submitPublication(
        descriptor,
        signature,
        requestToken
      );

      if (receipt.status !== 'PUBLISHED' ||
          receipt.request_token !== requestToken ||
          !receipt.publication_id) {
        throw new Error(`unexpected gateway receipt for ${bundleId}`);
      }

      await dbRun(
        conn,
        `INSERT INTO publications
          (bundle_id, artifact_count, total_bytes, key_id, descriptor,
           signature, request_token, publication_id, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        bundleId,
        artifactCount,
        totalBytes,
        signingKey.key_id,
        descriptor,
        signature,
        receipt.request_token,
        receipt.publication_id,
        receipt.status
      );

      outputLines.push(`BUNDLE ${bundleId} SIGNED KEY=${signingKey.key_id}`);
      outputLines.push(
        `BUNDLE ${bundleId} PUBLISHED RECEIPT=${receipt.publication_id}` +
        ` TOKEN=${receipt.request_token} STATUS=${receipt.status}`
      );
    }

    process.stdout.write(outputLines.join('\n') + (outputLines.length ? '\n' : ''));
  } finally {
    conn.close();
    db.close();
  }
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exitCode = 1;
});

NODE

chmod 0755 "$APP_ROOT/publisher/release-publisher.mjs"
echo "Installed $APP_ROOT/publisher/release-publisher.mjs"
