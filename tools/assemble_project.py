"""Assemble all validated build inputs, preserving vendor IP unchanged."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vendor-project', type=Path,
                        help='Optional matching vendor project; defaults to bundled vendor_original')
    parser.add_argument('--out', type=Path,
                        default=Path('build_workspace/candidate/project'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    vendor = args.vendor_project or root / 'vendor_original'
    items = json.loads((root / 'project_manifest.json').read_text(encoding='utf-8'))['files']
    target = args.out.resolve()
    if target.drive.upper() != 'D:':
        parser.error('Build outputs must be on D:')
    sources = []
    for item in items:
        source = vendor / item['project_path'] if item['external'] else root / item['public_path']
        if not source.is_file():
            parser.error('Missing dependency: ' + str(source))
        if hashlib.sha256(source.read_bytes()).hexdigest() != item['sha256']:
            parser.error('Hash mismatch: ' + str(source))
        destination = target / item['project_path']
        if destination.exists() and destination.read_bytes() != source.read_bytes():
            parser.error('Refusing to overwrite modified file: ' + str(destination))
        sources.append((source, destination))
    for source, destination in sources:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    print('PASS exact project assembly:', len(sources), 'files at', target)


if __name__ == '__main__':
    main()
