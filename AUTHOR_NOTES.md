# AUTHOR_NOTES.md

## What was fixed

The submission package previously failed the six-part completeness check because:
- `instruction.md` was a placeholder.
- `solution/publish.sh` was a no-op.
- the publisher implementation was incorrectly shipped under `environment/publisher/`.
- `AUTHOR_NOTES.md` was missing.
- the shipped verifier tests were unrelated to the firmware publisher task.

The corrected package keeps `environment/` as the immutable runtime fixture/service area and leaves `environment/publisher/` absent. The reference implementation is carried by `solution/publish.sh`; running it installs the actual entry point at `/app/publisher/release-publisher.mjs`.

## Reference implementation behavior

The publisher:
1. imports `/app/fixtures/build_manifest.csv` into DuckDB;
2. uses `SELECT DISTINCT` plus SQL withdrawal reconciliation;
3. drops fully withdrawn bundles naturally by grouping surviving builds;
4. canonicalizes descriptors as sorted-key, compact UTF-8 JSON;
5. signs exact descriptor bytes with the current `/app/keys/current/` certificate/key using OpenSSL CMS and SHA-256;
6. submits only through the documented gateway HTTP endpoints;
7. persists receipts and deterministic `token-<bundle_id>` request tokens in `/app/releases.duckdb`;
8. reuses persisted receipts on subsequent runs;
9. emits deterministic bundle-ordered status lines.

## Expected reconciliation

For the supplied fixture:
- `BND-101`: 9 surviving builds, 1,201,575 bytes.
- `BND-102`: 10 surviving builds, 2,188,075 bytes.
- `BND-103`: 8 surviving builds, 2,079,625 bytes.
- `BND-104`: omitted because both of its builds are withdrawn.

These values are sanity checks only; the implementation derives them from DuckDB SQL.

## Clean proof sequence

From `/app` in a clean container:

```bash
rm -f /app/releases.duckdb
rm -f /app/distribution-gateway/data/gateway.json

cd /app/distribution-gateway
node server.js
```

In a second shell:

```bash
cd /app
./solution/publish.sh
npm run report > /tmp/first.txt
npm run report > /tmp/second.txt
diff -u /tmp/first.txt /tmp/second.txt
```

Then compare the two output files with the receipt field masked against `/app/reports/publications.expected.txt`.

The gateway's private ledger must not be accessed by the publisher itself; it is only suitable for verifier-side inspection.
