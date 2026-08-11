import csv
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

import duckdb
import pytest

APP = Path("/app")
OUTPUT = Path(os.environ.get("PUBLISHER_OUTPUT", "/tmp/publisher-first.out"))
SECOND = Path(os.environ.get("PUBLISHER_OUTPUT_SECOND", "/tmp/publisher-second.out"))
EXPECTED = APP / "reports/publications.expected.txt"
DB = APP / "releases.duckdb"
LEDGER = APP / "distribution-gateway" / "data" / "gateway.json"
MANIFEST = APP / "fixtures" / "build_manifest.csv"


def masked(text: str) -> str:
    return re.sub(r"RECEIPT=[^ ]+", "RECEIPT=<id>", text)


def read_output(path: Path) -> str:
    assert path.exists(), f"missing publisher output: {path}"
    return path.read_text()


def test_report_output_matches():
    assert masked(read_output(OUTPUT)) == masked(EXPECTED.read_text())


def test_reconciliation_and_persistence():
    assert DB.exists()
    con = duckdb.connect(str(DB), read_only=True)
    try:
        rows = con.execute("""
            SELECT bundle_id, artifact_count, total_bytes, key_id,
                   request_token, publication_id, status
            FROM publications
            ORDER BY bundle_id
        """).fetchall()
        assert rows == [
            ("BND-101", 9, 1201575, "fw-signing-2026-current",
             "token-BND-101", rows[0][5], "PUBLISHED"),
            ("BND-102", 10, 2188075, "fw-signing-2026-current",
             "token-BND-102", rows[1][5], "PUBLISHED"),
            ("BND-103", 8, 2079625, "fw-signing-2026-current",
             "token-BND-103", rows[2][5], "PUBLISHED"),
        ]
        assert con.execute("SELECT COUNT(*) FROM manifest").fetchone()[0] == 40
    finally:
        con.close()


def test_current_key_signatures_verify():
    con = duckdb.connect(str(DB), read_only=True)
    try:
        rows = con.execute(
            "SELECT bundle_id, descriptor, signature FROM publications ORDER BY bundle_id"
        ).fetchall()
    finally:
        con.close()

    for bundle_id, descriptor, signature in rows:
        scratch = Path("/tmp") / f"verify-{bundle_id}"
        scratch.mkdir(exist_ok=True)
        descriptor_file = scratch / "descriptor.bin"
        signature_file = scratch / "signature.pem"
        descriptor_file.write_bytes(descriptor.encode())
        signature_file.write_text(signature)
        result = subprocess.run([
            "openssl", "cms", "-verify",
            "-inform", "PEM",
            "-in", str(signature_file),
            "-content", str(descriptor_file),
            "-certfile", "/app/keys/current/current.cert.pem",
            "-CAfile", "/app/keys/current/current.cert.pem",
            "-purpose", "any",
            "-no_check_time",
            "-binary",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        assert result.returncode == 0, result.stderr.decode()


def test_idempotent_rerun():
    assert SECOND.exists()
    assert read_output(OUTPUT) == read_output(SECOND)

    assert LEDGER.exists()
    ledger = json.loads(LEDGER.read_text())
    assert len(ledger["publications"]) == 3
    assert len(ledger["tokenIndex"]) == 3


def test_revoked_key_is_rejected():
    descriptor = b'{"artifact_count":1,"bundle_id":"NEGATIVE-CONTROL","total_bytes":100}'
    scratch = Path("/tmp/revoked-signature")
    scratch.mkdir(exist_ok=True)
    descriptor_file = scratch / "descriptor.bin"
    signature_file = scratch / "signature.pem"
    descriptor_file.write_bytes(descriptor)

    subprocess.run([
        "openssl", "cms", "-sign",
        "-in", str(descriptor_file),
        "-signer", "/app/keys/revoked/revoked.cert.pem",
        "-inkey", "/app/keys/revoked/revoked.key.pem",
        "-md", "sha256",
        "-outform", "PEM",
        "-binary",
        "-out", str(signature_file),
    ], check=True)

    body = json.dumps({
        "descriptor": descriptor.decode(),
        "signature": signature_file.read_text(),
        "request_token": "token-negative-control",
    }).encode()

    request = urllib.request.Request(
        "http://127.0.0.1:7070/v1/publications",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(request, timeout=10)

    payload = exc.value.read().decode()
    assert exc.value.code == 400
    assert "UNTRUSTED_SIGNATURE" in payload
