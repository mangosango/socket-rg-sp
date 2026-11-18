"""Run in the ARM64 builder with the patched RetroArch checkout as the working directory."""
import json
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading

source = Path.cwd()
objects = source / "obj-unix/release"
common = objects / "libretro-common"
probe = Path(__file__).with_name("retroarch_tls_probe.c").resolve()
backend = source / "libretro-common/net/net_socket_ssl_mbed.c"


def run(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


with tempfile.TemporaryDirectory() as directory:
    tmp = Path(directory)
    key, cert = tmp / "key.pem", tmp / "cert.pem"
    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
         "-out", cert, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"])
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    test_source = tmp / backend.name
    test_source.write_text(backend.read_text().replace('#include "../../socket_ca_bundle.h"', '#include "test_roots.h"'))
    (tmp / "test_roots.h").write_text("static const char cacert_pem[] = " + json.dumps(cert.read_text()) + ";")
    tls_object = tmp / "test-root.o"
    run(["cc", "-c", "-DHAVE_BUILTINMBEDTLS", "-I" + str(backend.parent),
         "-Ilibretro-common/include", str(test_source), "-o", tls_object])
    libs = [common / "net/net_socket.o", common / "net/net_compat.o",
            *sorted((objects / "deps/mbedtls").glob("*.o"))]
    for name, tls in [("stock-roots", common / "net/net_socket_ssl_mbed.o"), ("test-root", tls_object)]:
        run(["cc", "-Ilibretro-common/include", probe, tls, *libs, "-lm", "-lpthread", "-o", tmp / name])

    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen()
        server.settimeout(10)

        def serve():
            with server.accept()[0] as client:
                try:
                    with context.wrap_socket(client, server_side=True):
                        pass
                except ssl.SSLError:
                    pass

        for binary, hostname, expected in [("stock-roots", "localhost", 1), ("test-root", "localhost", 0),
                                            ("test-root", "wrong.example", 1)]:
            worker = threading.Thread(target=serve)
            worker.start()
            status = subprocess.run([tmp / binary, "127.0.0.1", str(server.getsockname()[1]), hostname],
                                    timeout=10).returncode
            worker.join()
            assert status == expected, (binary, hostname, status)
    print("PASS: valid certificate accepted, unknown issuer and wrong hostname rejected")
