#!/usr/bin/env python3
"""Publish pinned source bytes; never builds, signs, uploads an app, or uses secrets."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from urllib.parse import urlparse, quote

ROOT = Path(__file__).resolve().parent.parent
DEPENDENCIES = ROOT / 'source-dependencies'
VERSION = '1.0.0'
BUILD = '13'


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download(url, destination, expected):
    if urlparse(url).scheme != 'https' or urlparse(url).hostname not in {
        'codeload.github.com', 'media.githubusercontent.com', 'raw.githubusercontent.com'
    }:
        raise ValueError('Unexpected upstream origin')
    if destination.exists() and sha256(destination) == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + '.part')
    request = urllib.request.Request(url, headers={'User-Agent': 'CHIICH-open-source'})
    with urllib.request.urlopen(request, timeout=180) as response, temporary.open('wb') as output:
        shutil.copyfileobj(response, output)
    if sha256(temporary) != expected:
        temporary.unlink()
        raise ValueError('Upstream checksum mismatch: ' + destination.name)
    temporary.replace(destination)


def dependency(item):
    if item['status'] != 'verified-archive':
        return
    name = item['archive']
    if Path(name).name != name:
        raise ValueError('Invalid dependency archive name')
    target = DEPENDENCIES / name
    download(item['source_url'], target, item['sha256'])
    with tarfile.open(target) as archive:
        archive.getmembers()
    print('Verified dependency:', name, flush=True)


def main():
    lock = json.loads((ROOT / 'src/element-x-ios/upstream.lock.json').read_text())
    manifest = json.loads((DEPENDENCIES / 'manifest.json').read_text())
    # A workspace outside the repository prevents git apply from filtering paths
    # relative to an unrelated parent checkout.
    with tempfile.TemporaryDirectory(prefix='chiich-public-source-') as directory:
        workspace = Path(directory)
        archive = workspace / 'upstream.tar.gz'
        download(lock['archive_url'], archive, lock['archive_sha256'])
        app = workspace / 'app'
        subprocess.run(['python3', str(ROOT / 'src/element-x-ios/prepare.py'),
                        '--output', str(app), '--archive', str(archive)], check=True)
        subprocess.run(['python3', str(ROOT / 'src/element-x-ios/signing.py'),
                        'unsigned', '--source', str(app), '--version', VERSION,
                        '--build', BUILD, '--service-mode', 'links-only'], check=True)
        media = json.loads((DEPENDENCIES / 'development-media.json').read_text())
        for item in media:
            relative = Path(item['path'])
            if not str(relative).startswith('Components/DevelopmentAssets/Media/') or '..' in relative.parts:
                raise ValueError('Unexpected development media path')
            url = 'https://media.githubusercontent.com/media/element-hq/element-x-ios/' + lock['commit'] + '/' + quote(item['path'])
            download(url, app / relative, item['sha256'])
        # This standalone public snapshot has no upstream LFS object store.
        # Keep runtime media as normal Git blobs and preserve the original rules.
        attributes = app / '.gitattributes'
        attributes.rename(app / '.gitattributes.upstream')
        attributes.write_text('# Source snapshot: upstream rules are in .gitattributes.upstream.\n* -filter\n')
        destination = ROOT / 'app'
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(app, destination, symlinks=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        list(executor.map(dependency, manifest['dependencies']))
    subprocess.run(['sha256sum', '-c', 'SHA256SUMS'], cwd=DEPENDENCIES, check=True)
    files = sorted(path for path in (ROOT / 'app').rglob('*') if path.is_file())
    # Test screenshot LFS pointers are retained as upstream source metadata;
    # build-required development media above contains verified actual bytes.
    pointers = [str(path.relative_to(ROOT / 'app')) for path in files
                if path.stat().st_size < 256 and path.read_bytes().startswith(b'version https://git-lfs.github.com/spec/v1')]
    provenance = {
        'version': VERSION, 'build': BUILD, 'source_commit': manifest['application_source']['ref'],
        'build_workflow_run': manifest['application_source']['workflowRun'],
        'upstream_commit': lock['commit'], 'service_mode': 'links-only',
        'toolchain': manifest['build_environment'],
        'signing': 'Version and service configuration reproduced; private signing credentials excluded.',
        'development_media_files': len(media), 'test_snapshot_lfs_pointers': len(pointers),
        'test_snapshot_paths': pointers,
        'packaging': 'Original .gitattributes preserved as .gitattributes.upstream; LFS filtering disabled for this standalone source snapshot.',
        'dependency_manifest': 'source-dependencies/manifest.json',
        'validation': 'Source preparation, checksums and Python tests; no new Xcode build or App Store upload.'
    }
    (ROOT / 'SOURCE-PROVENANCE.json').write_text(json.dumps(provenance, indent=2) + '\n')
    checksum_files = files + [ROOT / 'SOURCE-PROVENANCE.json', DEPENDENCIES / 'manifest.json']
    (ROOT / 'SHA256SUMS').write_text(''.join(sha256(path) + '  ' + str(path.relative_to(ROOT)) + '\n' for path in sorted(checksum_files)))
    print('Source materialization complete:', len(files), 'application files')


if __name__ == '__main__':
    main()
