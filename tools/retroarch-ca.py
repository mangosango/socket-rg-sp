"""Embed the build image's CA roots in the BaseOS RetroArch binary."""
import json
from pathlib import Path

roots = Path("/etc/ssl/certs/ca-certificates.crt").read_text(encoding="ascii")
if "-----BEGIN CERTIFICATE-----" not in roots:
    raise SystemExit("Build image has no CA certificates")
Path("socket_ca_bundle.h").write_text("static const char cacert_pem[] =\n" +
                                      "\n".join(map(json.dumps, roots.splitlines(keepends=True))) + ";\n")
