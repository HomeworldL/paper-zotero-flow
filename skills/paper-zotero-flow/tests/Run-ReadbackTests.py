"""Actual orchestrator tests against an isolated, read-only loopback API."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
import uuid

SKILL = Path(__file__).resolve().parents[1]
PWSH = shutil.which('pwsh.exe') or shutil.which('pwsh')
PARENT = 'TESTP001'
QUERY = 'zotero:' + PARENT
PAPER = str(uuid.UUID(bytes_le=hashlib.md5(QUERY.lower().strip().encode()).digest()))
passed = failed = 0


def check(condition, name):
    global passed, failed
    if condition:
        passed += 1
        print('PASS: ' + name, flush=True)
    else:
        failed += 1
        print('FAIL: ' + name, flush=True)


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pdf(path, label):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>',
               b'<< /Length 0 >>\nstream\n\nendstream']
    data = b'%PDF-1.4\n%' + label.encode() + b'padding' * 300 + b'\n'
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += str(i).encode() + b' 0 obj\n' + obj + b'\nendobj\n'
    xref = len(data)
    data += b'xref\n0 5\n0000000000 65535 f \n'
    data += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets)
    data += f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    path.write_bytes(data)
    return path


with tempfile.TemporaryDirectory(prefix='pzf-readback-') as directory:
    root = Path(directory)
    files = [pdf(root / name, name) for name in ['source.pdf', 'mono.pdf', 'dual.pdf', 'other-mono.pdf', 'other-dual.pdf']]
    original, mono, dual, other_mono, other_dual = files
    requests, children = [], []
    collections = ['COLLTEST']

    def artifact(path, role):
        return dict(path=str(path), role=role, sha256=sha(path), verified=True, size_bytes=path.stat().st_size)

    def child(path, title, key):
        return dict(key=key, data=dict(itemType='attachment', contentType='application/pdf', title=title, filename=path.name), links=dict(enclosure=dict(href=path.as_uri())))

    def set_children(first, second):
        children[:] = [child(original, 'original', 'ORIG0001'), child(first, '中文 PDF', 'MONO0001')]
        if second:
            children.append(child(second, '双语 PDF', 'DUAL0001'))

    class API(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(('GET', self.path))
            path = urlparse(self.path).path
            if path == '/api/':
                value = {}
            elif path == '/api/users/0/items/' + PARENT:
                value = dict(key=PARENT, data=dict(itemType='journalArticle', title='Fixture', collections=collections))
            elif path == '/api/users/0/items/' + PARENT + '/children':
                value = children
            else:
                self.send_error(404)
                return
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Zotero-Server-ID', 'readback-fixture')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            requests.append(('POST', self.path))
            self.send_error(403)

        do_PUT = do_DELETE = do_POST

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), API)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for case, mode, pair, state, wrong_collection in [
            ('matching', 'verify', (mono, dual), 'attach', False),
            ('missing', 'translate', (mono, None), 'attach', False),
            ('mismatch-verify', 'verify', (other_mono, other_dual), 'attach', False),
            ('mismatch-resume', 'translate', (other_mono, other_dual), 'attach', False),
            ('wrong-collection', 'verify', (mono, dual), 'attach', True),
            ('unknown-ingest', 'translate', (mono, None), 'ingest', False),
            ('changed-local', 'translate', (mono, dual), 'attach', False),
        ]:
            if len(sys.argv) > 1 and sys.argv[1] != case:
                continue
            set_children(*pair)
            collections[:] = ['WRONGCOL' if wrong_collection else 'COLLTEST']
            requests.clear()
            run = root / 'runs' / case
            retained = run / 'stage-results' / PAPER / 'translate.json'
            outputs = [artifact(mono, 'translated'), artifact(dual, 'bilingual')]
            if case == 'changed-local':
                outputs[1]['sha256'] = 'f' * 64
            save(retained, dict(schema='translation-result.v1', schema_version=1, paper_id=PAPER, status='succeeded', inputs=dict(input_pdf=str(original)), outputs=dict(artifacts=outputs, attempts=[], service_used='qwenmt'), provenance=[], errors=[]))
            retained_hash = sha(retained)
            stages = dict(translate=dict(status='succeeded'), attach=dict(status='pending'), ingest=dict(status='succeeded'), verify=dict(status='pending'))
            unresolved_status = 'pending' if case == 'changed-local' else 'unknown'
            stages[state]['status'] = unresolved_status
            paper = dict(paper_id=PAPER, query=QUERY, pdf=artifact(original, 'original'), translations=outputs, zotero=dict(item_key=PARENT, server_id='readback-fixture', collection_key='COLLTEST'), artifact_translation_run=dict(service_used='qwenmt'), stage_states=stages, stage_history=[], status='failed', completion_verified=False)
            save(run / 'manifest.json', dict(schema_version=1, run_id=case, requested_mode='translate', requested_collection='COLLTEST', local_only=False, papers=[paper]))
            args = [PWSH, '-NoProfile', '-File', str(SKILL / 'scripts' / 'Invoke-PaperZoteroFlow.ps1'), '-Mode', mode, '-RunRoot', str(root / 'runs'), '-RunId', case, '-BaseUri', f'http://127.0.0.1:{server.server_port}/api/', '-SkillsRoot', str(root / 'no-provider-or-write-scripts')]
            if mode != 'verify':
                args += ['-ItemKey', PARENT, '-Resume']
            result = subprocess.run(args, capture_output=True, timeout=90)
            papers = json.loads((run / 'manifest.json').read_text(encoding='utf-8'))['papers']
            check(len(papers) == 1, case + ': resumes the original paper only')
            actual = papers[0]
            expected_success = case == 'matching'
            check((result.returncode == 0) == expected_success and actual['completion_verified'] == expected_success, case + ': honest completion verdict')
            check(retained.exists() and sha(retained) == retained_hash and actual['translations'] == outputs and actual['artifact_translation_run']['service_used'] == 'qwenmt', case + ': preserves expected outputs and provider provenance')
            check(all(method == 'GET' for method, _ in requests), case + ': read-only reconciliation')
            if not expected_success:
                check(actual['stage_states'][state]['status'] == unresolved_status, case + ': unresolved write state is preserved')
    finally:
        server.shutdown()
        server.server_close()

print(f'Result: {passed} passed, {failed} failed')
raise SystemExit(bool(failed))
