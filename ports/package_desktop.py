# SPDX-License-Identifier: MIT
import pathlib, sys, zipfile
name = sys.argv[1]
root = pathlib.Path('ports/desktop/build/compose/binaries/main/app/MusicSync')
assert root.is_dir(), f'Missing packaged app: {root}'
files = [p for p in root.rglob('*') if p.is_file()]
assert any(p.suffix == '.jar' for p in files), 'Missing app jars'
assert any(p.name in ('java', 'java.exe', 'libjvm.so', 'jvm.dll') for p in files), 'Missing bundled runtime'
if name == 'Windows':
    assert any(p.name == 'MusicSync.exe' for p in files), 'Missing Windows launcher'
else:
    assert any(p.name == 'MusicSync' for p in files), 'Missing Linux launcher'
dest = pathlib.Path('dist'); dest.mkdir(exist_ok=True)
with zipfile.ZipFile(dest / f'MusicSync-{name}.zip','w',zipfile.ZIP_DEFLATED) as z:
    for p in files: z.write(p, pathlib.Path('MusicSync')/p.relative_to(root))
print(f'Packaged {name}: {len(files)} files, bundled runtime')
