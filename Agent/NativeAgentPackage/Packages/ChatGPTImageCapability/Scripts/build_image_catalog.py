#!/usr/bin/env python3
"""Compile reviewed prompt sources; optionally import mobile WebP cards from the supplied ZIP.
Usage: python3 Scripts/build_image_catalog.py [--cards-zip PATH] [--check]
Requires Pillow with WebP support only when importing images. Never extracts archive paths into the repository.
"""
import argparse, hashlib, io, json, re, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'PromptSources'
OUTPUT = ROOT / 'Sources/ChatGPTImageCapability/Resources/ImageCatalog'

def digest(data): return hashlib.sha256(data).hexdigest()
def read(path): return json.loads(path.read_text())
def section(text, title):
    match = re.search(r'^## ' + re.escape(title) + r'\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    if not match: raise ValueError('Missing section: ' + title)
    return match[1].strip()

def build():
    controls = read(SOURCE / 'controls.json')
    prompts = []
    for path in sorted((SOURCE / 'universal').rglob('*.md')):
        text = path.read_text()
        match = re.search(r'^id: (.+)$', text, re.M)
        if not match: continue
        pid = match[1]
        template = re.search(r'```text\n(.*?)\n```', text, re.S)
        if not template: raise ValueError('Missing template: ' + pid)
        variables = re.findall(r'^- `([A-Z_]+)`', section(text, '선택 변수'), re.M)
        policy = controls[pid]
        if set(variables) != set(policy['requiredVariables']) | set(policy['defaults']):
            raise ValueError('Review controls for ' + pid)
        prompts.append(dict(id=pid, title=re.search(r'^# (.+)$', text, re.M)[1],
            summary=section(text,'목적'), mode=re.search(r'^mode: (.+)$',text,re.M)[1],
            category=re.search(r'^category: (.+)$',text,re.M)[1],
            source=str(path.relative_to(SOURCE)), template=template[1], variables=variables,
            failureCriteria=[x[2:] for x in section(text,'실패 기준').splitlines() if x.startswith('- ')], **policy))
    prompts += read(SOURCE / 'extensions.json')
    ids = [p['id'] for p in prompts]
    if len(ids) != len(set(ids)): raise ValueError('Duplicate prompt ID')
    categories = read(SOURCE / 'categories.json')
    for category in categories:
        if not category['promptIDs'] or not set(category['promptIDs']) <= set(ids):
            raise ValueError('Unmapped category: ' + category['id'])
        category['previewFile'] = category['id'] + '.webp'
        category['thumbnailFile'] = category['id'] + '-thumb.webp'
        for field in ['previewFile','thumbnailFile']:
            if not (OUTPUT / category[field]).is_file(): raise ValueError('Missing image: '+category[field])
    source_hashes = {str(p.relative_to(SOURCE)):digest(p.read_bytes()) for p in sorted(SOURCE.rglob('*')) if p.is_file()}
    revision = digest(json.dumps(source_hashes,sort_keys=True).encode())[:16]
    return dict(schemaVersion=1, revision=revision, prompts=prompts, categories=categories)

def import_cards(path):
    from PIL import Image, features
    if not features.check("webp"): raise ValueError("Pillow WebP support is required")
    manifest = []
    with zipfile.ZipFile(path) as archive:
        for category in read(SOURCE / 'categories.json'):
            name = category['id']
            data = archive.read('category-example-cards/' + name + '.png')
            if data[:8] != b'\x89PNG\r\n\x1a\n': raise ValueError('Invalid PNG')
            original = Image.open(io.BytesIO(data)).convert('RGB')
            width,height = original.size
            for suffix,max_edge in [('',960),('-thumb',480)]:
                scale=min(1,max_edge/max(width,height)); w,h=round(width*scale),round(height*scale)
                output=OUTPUT/(name+suffix+'.webp')
                original.resize((w,h),Image.Resampling.LANCZOS).save(output,format='WEBP',quality=84,method=6)
                manifest.append(dict(file=output.name,width=w,height=h,bytes=output.stat().st_size,
                    sha256=digest(output.read_bytes()),sourceSHA256=digest(data),sourceBytes=len(data)))
        # Retain attribution/context, not the redundant full contact sheet in the app bundle.
        (SOURCE/'CATEGORY_EXAMPLES.md').write_bytes(archive.read('category-example-cards/README.md'))
    (OUTPUT/'assets.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')

if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--cards-zip',type=Path);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    if args.check and args.cards_zip: parser.error('--check cannot import images')
    OUTPUT.mkdir(parents=True,exist_ok=True)
    if args.cards_zip: import_cards(args.cards_zip)
    catalog=build();encoded=json.dumps(catalog,ensure_ascii=False,indent=2)+'\n'
    if args.check:
        if (OUTPUT/'catalog.json').read_text()!=encoded: raise SystemExit('Catalog is stale; rebuild it')
        for asset in read(OUTPUT/'assets.json'):
            if digest((OUTPUT/asset['file']).read_bytes())!=asset['sha256']: raise SystemExit('Changed asset: '+asset['file'])
    else: (OUTPUT/'catalog.json').write_text(encoded)
    print(json.dumps(dict(status='PASS',revision=catalog['revision'],prompts=len(catalog['prompts']),categories=len(catalog['categories']),assetBytes=sum(x['bytes'] for x in read(OUTPUT/'assets.json')))))
