# Firmware Release Publisher — Candidate Instructions

Implement the publisher entry point at the absolute path `/app/publisher/release-publisher.mjs`.

## Inputs and runtime

- Raw manifest: `/app/fixtures/build_manifest.csv`.
- Golden output: `/app/reports/publications.expected.txt`.
- Runtime DuckDB database: `/app/releases.duckdb` (create it; do not ship a pre-created DB).
- Gateway base URL: `http://127.0.0.1:7070`.
- Current signing key: `/app/keys/current/current.key.pem`.
- Current signing certificate: `/app/keys/current/current.cert.pem`.
- Revoked key material under `/app/keys/revoked/` is a negative-control fixture only; never use it for publication.
- Run the publisher through `npm run report`, which executes `node publisher/release-publisher.mjs --report`.
- Do not modify `/app/distribution-gateway/`.

The gateway exposes:
- `GET /v1/signing-key/current`, returning `key_id`, `algorithm`, `certificate_ref`, and `status`.
- `POST /v1/publications` accepting `{descriptor, signature, request_token}` and returning a `PUBLISHED` receipt on success.
- A repeated `request_token` returns the original receipt without creating another publication.

## Manifest reconciliation

Load the complete CSV into DuckDB table `manifest`. Use SQL for reconciliation.

A row is an exact duplicate only when every manifest column is identical. Collapse exact duplicates before applying the remaining rules.

A `BUILD` survives unless at least one distinct `WITHDRAWAL` row has `supersedes_id` equal to that build's `entry_id`. The withdrawal cancels the referenced build by `entry_id`; do not require any other field to match.

A bundle is publishable when it has at least one surviving `BUILD`. If all builds in a bundle are withdrawn, omit that bundle entirely.

For each publishable bundle, derive in SQL:
- `artifact_count`: count of surviving builds.
- `total_bytes`: sum of surviving `size_bytes`.

Order bundles by `bundle_id` ascending.

For the supplied fixture, the publishable bundles are `BND-101`, `BND-102`, and `BND-103`; `BND-104` must be omitted. Do not hardcode these values: derive them from the CSV and SQL.

## Descriptor and signing

For every publishable bundle, first fetch the current signing metadata from `GET /v1/signing-key/current`.

Create the descriptor as UTF-8 JSON with:
- `artifact_count`
- `bundle_id`
- `total_bytes`

Object keys must be sorted lexicographically and there must be no insignificant whitespace. For example:
`{"artifact_count":9,"bundle_id":"BND-101","total_bytes":1201575}`

Sign the exact UTF-8 bytes of that descriptor with the current PEM keypair using OpenSSL CMS, SHA-256, PEM output, binary mode. The signature must be detached and must verify with the gateway command:

`openssl cms -verify -inform PEM -in <signature.pem> -content <descriptor.bin> -certfile /app/keys/current/current.cert.pem -CAfile /app/keys/current/current.cert.pem -purpose any -no_check_time -binary`

Never sign with `/app/keys/revoked/`. Never bypass verification.

## Submission and persistence

Submit each bundle over HTTP only. Do not read or write `/app/distribution-gateway/data/gateway.json`.

Use the deterministic request token `token-<bundle_id>`.

Create `/app/releases.duckdb` with a persistence table containing at least:
`bundle_id`, `artifact_count`, `total_bytes`, `key_id`, `descriptor`, `signature`, `request_token`, `publication_id`, and `status`.

Before submitting a bundle, check DuckDB for an existing `PUBLISHED` receipt for that bundle/request token. If one exists, reuse it and do not submit again. If a submission succeeds, persist the returned `publication_id`, echoed `request_token`, and `status` before finishing the bundle.

A second run must produce byte-identical stdout and must not create additional gateway publications.

## Required stdout

For every publishable bundle, emit exactly two lines, in ascending `bundle_id` order:

`BUNDLE <bundle_id> SIGNED KEY=<key_id>`
`BUNDLE <bundle_id> PUBLISHED RECEIPT=<publication_id> TOKEN=<request_token> STATUS=PUBLISHED`

Do not print extra status lines to stdout. Errors may go to stderr and the process must exit non-zero.

## Success condition

The implementation is complete only when, in a clean container with the gateway running:

1. `npm run report` succeeds.
2. Its output matches `/app/reports/publications.expected.txt` after masking only the random `RECEIPT=<publication_id>` value.
3. Every publication is accepted as `PUBLISHED` with the current key.
4. `/app/releases.duckdb` contains one persisted receipt/token per publishable bundle.
5. Running `npm run report` a second time produces identical output and no duplicate publication.
