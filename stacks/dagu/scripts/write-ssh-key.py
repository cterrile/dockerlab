#!/usr/bin/env python3
import os
import subprocess
import sys

raw = sys.stdin.read()
if not raw.strip():
    print("ERROR: SSH private key input is empty", file=sys.stderr)
    sys.exit(1)

key = raw.replace("\r\n", "\n").replace("\r", "\n")
if "-----BEGIN" in key and key.count("\n") < 2 and "\\n" in key:
    key = key.replace("\\n", "\n")
if not key.endswith("\n"):
    key += "\n"

key_path = os.environ.get("SSH_KEY_PATH", "/home/dagu/.ssh/id_ed25519")
ssh_dir = os.path.dirname(key_path)
os.makedirs(ssh_dir, mode=0o700, exist_ok=True)

with open(key_path, "w", encoding="utf-8") as fh:
    fh.write(key)
os.chmod(key_path, 0o600)

try:
    subprocess.run(
        ["ssh-keygen", "-y", "-f", key_path],
        check=True,
        capture_output=True,
        text=True,
    )
except subprocess.CalledProcessError as exc:
    print(
        "ERROR: SSH private key is invalid after write "
        "(store a full OpenSSH private key in Infisical)",
        file=sys.stderr,
    )
    if exc.stderr:
        print(exc.stderr.strip(), file=sys.stderr)
    sys.exit(1)
