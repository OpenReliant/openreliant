"""Issue disposable identities for headless transport tests."""

import hashlib
from pathlib import Path
import subprocess
import tempfile
import time

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def encode(protoc, schema, message, fields):
    return subprocess.run(
        [protoc, "-I", str(schema.parent), "--encode=" + message, schema.name],
        input=fields.encode("ascii"), stdout=subprocess.PIPE, check=True,
    ).stdout


def literal(data):
    # Protobuf's text format accepts octal escapes for every byte.
    return '"' + "".join(f"\\{byte:03o}" for byte in data) + '"'


def issue(directory, schema, protoc="protoc", *, late_pilot=False):
    if directory.exists():
        raise FileExistsError(directory)
    # Publish the set only after every certificate has been signed.
    with tempfile.TemporaryDirectory(dir=directory.parent) as temporary:
        stage = Path(temporary)
        write_identities(stage, schema, protoc, late_pilot)
        stage.rename(directory)


def write_identities(directory, schema, protoc, late_pilot):
    ca = Ed25519PrivateKey.generate()
    public = ca.public_key()
    key_id = int.from_bytes(hashlib.sha256(public.public_bytes_raw()).digest()[:8], "little")
    ssh = public.public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
    (directory / "root.pub").write_bytes(ssh + f" ID{key_id}\n".encode())
    now = int(time.time())
    names = ["host", "pilot1", "pilot2"]
    if late_pilot:
        names.append("pilot3")
    for name in names:
        key = Ed25519PrivateKey.generate()
        cert = encode(protoc, schema, "CMsgSteamDatagramCertificate", f"""
            key_type: ED25519
            key_data: {literal(key.public_key().public_bytes_raw())}
            app_ids: 0
            identity_string: "str:{name}"
            time_created: {now - 60}
            time_expiry: {now + 86400}
        """)
        signed = encode(protoc, schema, "CMsgSteamDatagramCertificateSigned", f"""
            cert: {literal(cert)}
            ca_key_id: {key_id}
            ca_signature: {literal(ca.sign(cert))}
            private_key_data: {literal(key.private_bytes_raw())}
        """)
        path = directory / (name + ".cert")
        path.touch(mode=0o600, exist_ok=False)
        path.write_bytes(signed)
