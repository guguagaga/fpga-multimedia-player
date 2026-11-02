"""Verify submission source and media-tool identities without running FPGA tools."""

import hashlib
import json
import argparse
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vendor-project', type=Path,
                        help='Matching external project containing the 19 vendor inputs')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / 'project_manifest.json').read_text(encoding='utf-8'))
    names = set()
    public_count = external_count = 0
    for item in manifest['files']:
        if item['project_path'] in names:
            raise RuntimeError('Duplicate project input: ' + item['project_path'])
        names.add(item['project_path'])
        if item['external']:
            if item['public_path'] is not None:
                raise RuntimeError('External dependency must have no public path')
            if args.vendor_project is None:
                continue
            path = args.vendor_project.resolve() / item['project_path']
            if not path.is_file() or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
                raise RuntimeError('Vendor input mismatch: ' + str(path))
            external_count += 1
            continue
        path = root / item['public_path']
        if not path.is_file() or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise RuntimeError('Project input mismatch: ' + str(path))
        public_count += 1
    tools_root = root / 'host/video/codec14'
    tools = json.loads((tools_root / 'tool_manifest.json').read_text(encoding='utf-8'))
    for name, expected in tools['files'].items():
        if digest(tools_root / name) != expected:
            raise RuntimeError('Encoder tool mismatch: ' + name)
    print(f'PASS: {public_count} public source/template inputs')
    if args.vendor_project is None:
        print('NOT CHECKED: 19 external vendor inputs; pass --vendor-project for a complete check.')
    else:
        print(f'PASS: {external_count} external vendor inputs')
    print(f'PASS: {len(tools["files"])} media-tool identities')
    print('Scope: file identity only; physical implementation and board tests are separate.')


if __name__ == '__main__':
    main()
