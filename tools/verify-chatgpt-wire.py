#!/usr/bin/env python3
"""Exact-source wire/lifecycle tests and real URLSession over a local HTTP socket.
Does not replace Keychain, CryptoKit, login, ModelClient or live ChatGPT with stubs.
"""
from pathlib import Path
import argparse
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import traceback

from apple_package_runner import uses_xcode_ios_runner, xcodebuild_command

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/verification/current'
MODULES = {
    'ChatGPTAccount': ('Account', ['ChatGPTProtocol.swift', 'ChatGPTAccountPayload.swift', 'ChatGPTTransport.swift']),
    'ChatGPTText': ('Text', ['ChatGPTTextTypes.swift', 'ChatGPTTextPayload.swift', 'SSEParser.swift', 'ChatGPTTextWire.swift', 'ChatGPTToolWireCodec.swift']),
    'ChatGPTImage': ('Image', ['ChatGPTImageTypes.swift', 'ChatGPTImageLimits.swift', 'ChatGPTImageWireCodec.swift']),
}
TESTS = ['ChatGPTAccountPayloadTests.swift', 'ChatGPTImageErrorTests.swift',
         'ChatGPTWireBoundaryTests.swift', 'ChatGPTTransportLifecycleTests.swift', 'ChatGPTURLSessionTests.swift']
TIMEOUT_SECONDS = 240

@contextmanager
def http_fixture():
    stopping = threading.Event()
    requests = []
    fixture_errors = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args):
            pass
        def handle(self):
            try:
                super().handle()
            except (ConnectionResetError, BrokenPipeError):
                # Deliberate client cancellation may also interrupt the next keepalive read.
                self.close_connection = True
        def end_headers(self):
            self.send_header('Connection', 'close')
            super().end_headers()
        def do_GET(self):
            self.close_connection = True
            with lock:
                requests.append(self.path)
            try:
                if self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location', '/redirect-target')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                self.send_response(200)
                if self.path in ('/stall', '/chunked-large', '/sse'):
                    self.send_header('Transfer-Encoding', 'chunked')
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()
                    data = ('data: 한글\n\ndata: done\n\n'.encode() if self.path == '/sse' else b'0123456789')
                    # Separate writes include UTF-8 codepoints split across chunk frames.
                    for byte in data:
                        self.wfile.write(b'1\r\n' + bytes([byte]) + b'\r\n')
                        self.wfile.flush()
                    if self.path == '/stall':
                        stopping.wait(TIMEOUT_SECONDS)
                    self.wfile.write(b'0\r\n\r\n')
                    self.wfile.flush()
                    return
                body = b'hello'
                self.send_header('Content-Length', '1024' if self.path == '/truncated' else str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                if self.path == '/truncated':
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
            except (BrokenPipeError, ConnectionResetError):
                # Client cancellation/limits intentionally close the socket.
                self.close_connection = True

    class Server(ThreadingHTTPServer):
        daemon_threads = False
        block_on_close = True
        def handle_error(self, request, client_address):
            with lock:
                fixture_errors.append(traceback.format_exc())
            super().handle_error(request, client_address)

    server = Server(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}', requests, fixture_errors
    finally:
        stopping.set()
        server.shutdown()
        server.server_close()
        thread.join()


def run(work):
    if work == ROOT or work.is_relative_to(ROOT):
        raise SystemExit('Qualification scratch must be outside the source workspace.')
    OUT.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    for directory in ('Sources', 'Tests'):
        shutil.rmtree(work / directory, ignore_errors=True)
    files = []
    def copy(source, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        files.append({'source': str(source.relative_to(ROOT)), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    for module, (package, names) in MODULES.items():
        for name in names:
            copy(ROOT/'Providers/ChatGPT'/package/'Sources'/module/name, work/'Sources'/module/name)
    test_root = ROOT/'Qualification/ChatGPTCompositionChecks/Tests/ChatGPTCompositionTests'
    for name in TESTS:
        copy(test_root/name, work/'Tests/ChatGPTWireTests'/name)
    core = ROOT/'Model/LanguageModelCore'
    for source in [core/'Package.swift', *sorted((core/'Sources').rglob('*'))]:
        if source.is_file():
            files.append({'source': str(source.relative_to(ROOT)), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
    let package = Package(name: "ChatGPTWireQualification", platforms: [.iOS(.v17)], dependencies: [.package(path: CORE)], targets: [
.target(name: "ChatGPTAccount", swiftSettings: strict),
.target(name: "ChatGPTText", dependencies: ["ChatGPTAccount", .product(name: "LanguageModelCore", package: "LanguageModelCore")], swiftSettings: strict),
.target(name: "ChatGPTImage", dependencies: ["ChatGPTAccount"], swiftSettings: strict),
.testTarget(name: "ChatGPTWireTests", dependencies: ["ChatGPTText", "ChatGPTImage", "ChatGPTAccount", .product(name: "LanguageModelCore", package: "LanguageModelCore")], swiftSettings: strict)
], swiftLanguageModes: [.v6])
'''.replace('path: CORE', 'path: ' + json.dumps(str(core)))
    (work/'Package.swift').write_text(manifest)
    if uses_xcode_ios_runner():
        command = xcodebuild_command(work, 'test', work/'.derived-data')
    else:
        command = ['swift', 'test', '--package-path', str(work), '-j', '4', '-Xswiftc', '-warnings-as-errors']
    with http_fixture() as (url, requests, fixture_errors):
        environment = {**os.environ, 'NATIVEAI_HTTP_FIXTURE_URL': url}
        with (OUT/'chatgpt-wire.log').open('w') as log:
            with subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True) as process:
                try:
                    code = process.wait(timeout=TIMEOUT_SECONDS)
                except (subprocess.TimeoutExpired, KeyboardInterrupt):
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    code = 124
                    log.write('\nQualification interrupted; owned compiler/test process group terminated.\n')
        forbidden = [p for p in requests if p in ('/redirect-target', '/must-not-dispatch')]
    text = (OUT/'chatgpt-wire.log').read_text()
    counts = re.findall(r'Test run with (\d+) tests? .*passed', text)
    report = {
        'status': 'PASS' if code == 0 and not forbidden and not fixture_errors else 'FAIL',
        'exitCode': code, 'command': command,
        'swiftTestingCount': int(counts[-1]) if counts else None,
        'scope': files,
        'localHTTP': {'requests': requests, 'forbiddenDispatches': forbidden, 'fixtureErrors': fixture_errors,
                      'mechanism': 'Production URLSessionChatGPTTransport + local HTTP sockets; no URLProtocol replacement.'},
        'excluded': ['ChatGPTAccountSession/CryptoKit/Keychain/loopback login', 'ChatGPTTextSession/ModelClient',
                     'ChatGPTImageClient', 'Agent adapters', 'live ChatGPT account/network E2E'],
        'note': 'Gate fixtures prove ordering only. On macOS the test runs on the discovered iOS Simulator. Local URLSession tests prove real local HTTP behavior, not ChatGPT service compatibility.',
    }
    (OUT/'chatgpt-wire.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in ('status', 'exitCode', 'swiftTestingCount')}), flush=True)
    return 0 if report['status'] == 'PASS' else 1

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch', type=Path, help='Optional reusable exact-source qualification directory outside the workspace')
    args = parser.parse_args()
    if args.scratch:
        raise SystemExit(run(args.scratch.resolve()))
    with tempfile.TemporaryDirectory(prefix='chatgpt-exact-wire-') as directory:
        raise SystemExit(run(Path(directory)))
