"""Serve the verified text checkpoint with an installed Nativ macOS runtime."""
import hashlib
import os
from pathlib import Path
import sys

WEIGHTS_HASH = "c30cf8cff1554a94e42186f2293b8069930599234327d1fd002ac4f92e4ad136"
SERVER = Path("Contents/Frameworks/NativServerKit.framework/Versions/A/Resources/mlx-vlm-server/bin/mlx-vlm-server")
PORT = 18985


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: python3 start-nativ.py /path/to/Nativ.app /path/to/Pin-Qwen-6bit")
    app, model = (Path(arg).expanduser().resolve() for arg in sys.argv[1:])
    weights = model / "model.safetensors"
    if model.name != "Pin-Qwen-6bit" or not weights.is_file():
        sys.exit("Expected the unpacked Pin-Qwen-6bit directory with full weights.")
    server = app / SERVER
    if not os.access(server, os.X_OK):
        sys.exit("Nativ server executable missing. Check the Nativ.app path and version.")
    digest = hashlib.sha256()
    with weights.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != WEIGHTS_HASH:
        sys.exit("Checkpoint checksum differs from the verified release.")
    os.chdir(model.parent)
    env = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    env.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
               MLX_VLM_MODEL_PATHS=str(model.parent), APC_ENABLED="1", APC_DISK_ENABLED="0")
    profile = (f'(version 1)(allow default)(deny network*)'
               f'(allow network-bind (local ip "localhost:{PORT}"))'
               f'(allow network-inbound (local ip "localhost:{PORT}"))'
               '(allow network-outbound (remote ip "localhost:*"))')
    os.execve("/usr/bin/sandbox-exec", ["sandbox-exec", "-p", profile, str(server),
              "--host", "127.0.0.1", "--port", str(PORT), "--model", "./"+model.name,
              "--model-dir", str(model.parent), "--max-num-seqs", "1", "--max-tokens", "4096"], env)


if __name__ == "__main__":
    main()
