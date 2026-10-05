#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 ACOPS1206
"""Publish verified CI binaries without rebuilding or altering tested application sources."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

REPO = os.environ['GITHUB_REPOSITORY']
TAG = os.environ['RELEASE_TAG']
TARGET = os.environ['RELEASE_SHA']
if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?', TAG):
    raise SystemExit('Invalid release tag')
if not re.fullmatch(r'[0-9a-f]{40}', TARGET):
    raise SystemExit('Use the full tested source commit SHA')

def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)

def api(path):
    return json.loads(gh('api', f'repos/{REPO}/{path}'))

def verify_run(env, workflow, paths):
    run_id = os.environ[env]
    if not run_id.isdecimal():
        raise SystemExit('Invalid workflow run ID')
    run = api(f'actions/runs/{run_id}')
    if (run['conclusion'] != 'success' or run['head_branch'] != 'main'
            or run['head_repository']['full_name'] != REPO
            or run['path'] != workflow or run['event'] not in ('push', 'workflow_dispatch')):
        raise SystemExit(f'Only successful trusted main builds are releasable: {env}')
    subprocess.run(['git', 'diff', '--exit-code', run['head_sha'], TARGET, '--', *paths], check=True)
    print(f'Verified {env}: {run_id}, source {run["head_sha"]}')
    return run_id

APPLE = verify_run('APPLE_RUN', '.github/workflows/build.yml', [
    'AppShared', 'Shared', 'macOS', 'iOS', 'MusicSync.xcodeproj',
    'scripts/generate_project.py', 'scripts/build.sh', 'scripts/package.py',
    'scripts/test_audio.sh', 'scripts/test_pairing.sh', '.github/workflows/build.yml'])
WEB = verify_run('WEB_RUN', '.github/workflows/web.yml', [
    'web', 'Shared/MusicSyncCore', '.github/workflows/web.yml',
    'scripts/WebInteropHost.swift', 'scripts/test_web_interop.sh'])
PORTS = verify_run('PORTS_RUN', '.github/workflows/ports.yml', [
    'ports', 'Shared/MusicSyncCore', '.github/workflows/ports.yml',
    'scripts/PortsInterop.swift', 'scripts/PortsInteropHost.swift', 'scripts/test_ports_interop.sh'])

notes = Path('release-notes', TAG + '.md')
if not notes.is_file():
    raise SystemExit('Write release notes before publishing')
assets = Path('dist/release')
assets.mkdir(parents=True, exist_ok=True)
if list(assets.iterdir()):
    raise SystemExit('Release directory must be empty')

specs = [
    (APPLE, 'MusicSync-iOS', [('MusicSync-iOS.ipa', 'MusicSync-iOS.ipa'), ('MusicSync-iOS.app.zip', 'MusicSync-iOS.app.zip')]),
    (APPLE, 'MusicSync-macOS', [('MusicSync-macOS.zip', 'MusicSync-macOS.zip')]),
    (WEB, 'MusicSync-Web', [('MusicSync-Web.zip', 'MusicSync-Web.zip')]),
    (PORTS, 'MusicSync-Android', [('MusicSync-Android.apk', 'MusicSync-Android.apk')]),
    (PORTS, 'MusicSync-Windows', [('MusicSync-Windows.zip', 'MusicSync-Windows.zip'), ('*.msi', 'MusicSync-Windows.msi')]),
    (PORTS, 'MusicSync-Linux', [('MusicSync-Linux.zip', 'MusicSync-Linux.zip'), ('*.deb', 'MusicSync-Linux-amd64.deb'), ('*.rpm', 'MusicSync-Linux-x86_64.rpm')]),
]
for run_id, name, files in specs:
    candidates = [a for a in api(f'actions/runs/{run_id}/artifacts?per_page=100')['artifacts'] if a['name'] == name and not a['expired']]
    if len(candidates) != 1:
        raise SystemExit(f'Missing or ambiguous artifact: {name}')
    with tempfile.TemporaryDirectory() as temp:
        gh('run', 'download', run_id, '--repo', REPO, '--name', name, '--dir', temp)
        for pattern, output in files:
            matches = [p for p in Path(temp).rglob(pattern) if p.is_file()]
            if len(matches) != 1 or matches[0].stat().st_size == 0:
                raise SystemExit(f'Missing or ambiguous binary: {pattern}')
            shutil.copyfile(matches[0], assets / output)

# Check the actual downloadable archives, not just their filenames.
for name in ['MusicSync-iOS.ipa', 'MusicSync-iOS.app.zip', 'MusicSync-macOS.zip',
             'MusicSync-Web.zip', 'MusicSync-Windows.zip', 'MusicSync-Linux.zip', 'MusicSync-Android.apk']:
    with zipfile.ZipFile(assets / name) as archive:
        if archive.testzip() is not None:
            raise SystemExit(f'Corrupt archive: {name}')
        names = archive.namelist()
        if name == 'MusicSync-iOS.ipa' and 'Payload/MusicSync.app/Info.plist' not in names:
            raise SystemExit('IPA Payload layout mismatch')
        if name == 'MusicSync-Web.zip':
            if not {'server.mjs', 'public/app.mjs', 'README.ko.md', 'LICENSE'} <= set(names):
                raise SystemExit('Incomplete web package')
            if any('.local/' in p or p.endswith(('.key', '.crt')) or 'pairings.json' in p for p in names):
                raise SystemExit('Private web credentials must never be published')

binary_files = sorted(assets.iterdir())
checksums = '\n'.join(f'{hashlib.file_digest(p.open("rb"), "sha256").hexdigest()}  {p.name}' for p in binary_files) + '\n'
(assets / 'SHA256SUMS.txt').write_text(checksums)
# Drafts can have an uncreated tag; discover them by release ID, not /releases/tags.
matches = [r for r in api('releases?per_page=100') if r['tag_name'] == TAG]
if len(matches) > 1:
    raise SystemExit('Ambiguous release')
release = matches[0] if matches else None
if release:
    if not release['draft'] or release['target_commitish'] != TARGET:
        raise SystemExit('Existing published release or different draft target; nothing overwritten')
else:
    try:
        api(f'git/ref/tags/{TAG}')
    except subprocess.CalledProcessError:
        pass
    else:
        raise SystemExit('Tag already exists; choose a new version')
    # A draft isolates upload failures. Publish only after every asset is present.
    gh('release', 'create', TAG, '--repo', REPO, '--target', TARGET, '--draft',
       '--title', f'MusicSync {TAG} — Web & multi-platform apps', '--notes-file', str(notes))
    matches = [r for r in api('releases?per_page=100') if r['tag_name'] == TAG]
    if len(matches) != 1 or not matches[0]['draft']:
        raise SystemExit('Draft creation verification failed')
    release = matches[0]

release_id = release['id']
uploaded = {a['name']: a for a in api(f'releases/{release_id}')['assets']}
missing = []
for path in assets.iterdir():
    asset = uploaded.get(path.name)
    if asset is None:
        missing.append(str(path))
    elif (asset['size'] != path.stat().st_size or not asset.get('digest')
          or asset['digest'] != 'sha256:' + hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()):
        raise SystemExit('Existing draft asset mismatch; no asset overwritten')
if missing:
    gh('release', 'upload', TAG, '--repo', REPO, *sorted(missing))
release = api(f'releases/{release_id}')
uploaded = {a['name']: a for a in release['assets']}
for path in assets.iterdir():
    if path.name not in uploaded or uploaded[path.name]['size'] != path.stat().st_size:
        raise SystemExit('Incomplete upload; release remains a draft')
    digest = uploaded[path.name].get('digest')
    if digest and digest != 'sha256:' + hashlib.file_digest(path.open('rb'), 'sha256').hexdigest():
        raise SystemExit('Upload checksum mismatch; release remains a draft')
gh('api', '--method', 'PATCH', f'repos/{REPO}/releases/{release_id}', '-F', 'draft=false', '-f', 'make_latest=true')
release = api(f'releases/{release_id}')
if release['draft'] or len(release['assets']) != len(list(assets.iterdir())):
    raise SystemExit('Published release verification failed')
print(f'Published {release["html_url"]}: {len(release["assets"])} verified assets')
with open(os.environ.get('GITHUB_STEP_SUMMARY', os.devnull), 'a') as summary:
    summary.write(f'## MusicSync release\n\n[{TAG}]({release["html_url"]})\n\n')
    for asset in release['assets']:
        summary.write(f'- [{asset["name"]}]({asset["browser_download_url"]}) ({asset["size"]:,} bytes)\n')
