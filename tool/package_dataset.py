#!/usr/bin/env python3
"""Packages the hex data set (dataset/, see its README) for the Hugging Face Hub.

    python3 -m venv .venv && .venv/bin/pip install -r tool/requirements.txt
    .venv/bin/python tool/package_dataset.py [--dataset dataset] [--out dataset/hf]

Build the data set first (DATASET_DIR=$PWD/dataset flutter test
test/build_dataset_test.dart). This writes a folder that is a Hub dataset
repository as it stands:

    README.md                     the dataset card, with the configs below
    hexes/train-*.parquet         a row per labelled hex picture (hexes.csv),
                                  the picture embedded: the default config
    photos/train-*.parquet        a row per photo (photos.csv), the photo
                                  embedded, with its placement overlay where
                                  it is labelled
    extras/                       manifest.json, the truths, the saved games'
                                  session.json files, the devices' correction
                                  logs and the data set's own README, for
                                  provenance

Parquet because the Hub's viewer and the `datasets` library read it as it is
-- images as {bytes, path} structs, declared as Image features in each file's
metadata, so `load_dataset` decodes them -- with typed columns and few files.
Upload with the Hub's command line tool once the card's licence is settled:

    hf upload <user>/<repo> dataset/hf . --repo-type dataset

Nothing is uploaded by this script.
"""

import argparse
import csv
import json
import shutil
import struct
import sys
from pathlib import Path

try:
    import pyarrow as pa
    import pyarrow.parquet as pq
except ImportError:
    sys.exit('pyarrow is needed: python3 -m venv .venv && '
             '.venv/bin/pip install -r tool/requirements.txt')


def image_size(data: bytes):
    """(width, height) of a PNG or JPEG, read from its header; None if neither."""
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return struct.unpack('>II', data[16:24])
    if data[:2] == b'\xff\xd8':
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            length = struct.unpack('>H', data[i + 2:i + 4])[0]
            # Start-of-frame markers carry the size; the rest are skipped.
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                height, width = struct.unpack('>HH', data[i + 5:i + 9])
                return width, height
            i += 2 + length
    return None


IMAGE = pa.struct([('bytes', pa.binary()), ('path', pa.string())])


def image_value(path: Path, name: str):
    return {'bytes': path.read_bytes(), 'path': name}


def hf_features(schema: pa.Schema, images):
    """The `datasets` features for [schema]: [images] are Image columns."""
    names = {pa.string(): 'string', pa.int32(): 'int32', pa.float32(): 'float32', pa.bool_(): 'bool'}
    features = {}
    for field in schema:
        if field.name in images:
            features[field.name] = {'_type': 'Image'}
        else:
            features[field.name] = {'dtype': names[field.type], '_type': 'Value'}
    return features


def write_parquet(rows, schema, images, folder: Path, shard_bytes: int, row_group: int):
    """Writes [rows] as train-NNNNN-of-NNNNN.parquet shards of about [shard_bytes]."""
    folder.mkdir(parents=True, exist_ok=True)
    meta = {b'huggingface': json.dumps({'info': {'features': hf_features(schema, images)}}).encode()}
    schema = schema.with_metadata(meta)

    def size(row):
        return sum(len(row[c]['bytes']) for c in images if row.get(c)) + 1000

    shards, current, current_size = [], [], 0
    for row in rows:
        if current and current_size + size(row) > shard_bytes:
            shards.append(current)
            current, current_size = [], 0
        current.append(row)
        current_size += size(row)
    if current:
        shards.append(current)
    for old in folder.glob('train-*.parquet'):
        old.unlink()
    for n, shard in enumerate(shards):
        table = pa.Table.from_pylist(shard, schema=schema)
        pq.write_table(table, folder / f'train-{n:05d}-of-{len(shards):05d}.parquet',
                       row_group_size=row_group, compression='zstd')
    return len(shards)


def number(value, kind):
    if value in ('', None):
        return None
    return kind(value)


def hexes_rows(root: Path):
    schema = pa.schema([
        ('image', IMAGE),
        ('source', pa.string()), ('photo', pa.string()), ('device', pa.string()),
        ('title', pa.string()), ('truth', pa.string()), ('hex', pa.string()),
        ('label', pa.string()), ('tile', pa.string()), ('rotation', pa.int32()),
        ('colour', pa.string()), ('glare', pa.float32()), ('hex_px', pa.int32()),
        ('facing', pa.int32()), ('read_as', pa.string()), ('read_confidence', pa.float32()),
        ('read_right', pa.bool_()),
    ])
    rows = []
    with open(root / 'hexes.csv', newline='') as f:
        for r in csv.DictReader(f):
            rows.append({
                'image': image_value(root / r['image'], r['image']),
                'source': r['source'], 'photo': r['photo'] or None, 'device': r['device'],
                'title': r['title'], 'truth': r['truth'], 'hex': r['hex'],
                'label': r['label'], 'tile': r['tile'], 'rotation': int(r['rotation']),
                'colour': r['colour'], 'glare': number(r['glare'], float),
                'hex_px': number(r['hex_px'], int), 'facing': number(r['facing'], int),
                'read_as': r['read_as'] or None,
                'read_confidence': number(r['read_confidence'], float),
                'read_right': None if r['read_right'] == '' else r['read_right'] == 'true',
            })
    return rows, schema


def photos_rows(root: Path):
    manifest = json.loads((root / 'manifest.json').read_text())
    truths = manifest['truths']
    by_file = {p['file']: p for p in manifest['photos']}
    schema = pa.schema([
        ('image', IMAGE), ('file', pa.string()), ('device', pa.string()),
        ('taken', pa.string()), ('what', pa.string()), ('title', pa.string()),
        ('labelled', pa.bool_()), ('truth', pa.string()), ('points', pa.string()),
        ('width', pa.int32()), ('height', pa.int32()), ('fit', IMAGE),
    ])
    rows = []
    with open(root / 'photos.csv', newline='') as f:
        for r in csv.DictReader(f):
            path = root / r['file']
            data = path.read_bytes()
            size = image_size(data) or (None, None)
            spec = by_file.get(r['file'])
            truth = spec['truth'] if spec else None
            title = r.get('title') or (
                (truths[truth].get('title') or manifest['title']) if truth else None)
            fit = root / 'fits' / f"{spec['id']}.jpg" if spec else None
            rows.append({
                'image': {'bytes': data, 'path': r['file']},
                'file': r['file'], 'device': r['device'], 'taken': r['taken'],
                'what': r['what'] or None, 'title': title,
                'labelled': spec is not None, 'truth': truth,
                'points': spec.get('points') if spec else None,
                'width': size[0], 'height': size[1],
                'fit': image_value(fit, f'fits/{fit.name}') if fit and fit.exists() else None,
            })
    return rows, schema


def copy_extras(root: Path, out: Path):
    extras = out / 'extras'
    if extras.exists():
        shutil.rmtree(extras)
    extras.mkdir(parents=True)
    for name in ('manifest.json', 'photos.csv', 'hexes.csv'):
        shutil.copy2(root / name, extras / name)
    shutil.copy2(root / 'README.md', extras / 'dataset-README.md')
    shutil.copytree(root / 'truth', extras / 'truth')
    for session in sorted((root / 'games').glob('*/*/session.json')):
        target = extras / session.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(session, target)
    for log in sorted((root / 'training').glob('*/labels.jsonl')):
        target = extras / log.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(log, target)


def card(hexes, photos, hex_shards, photo_shards):
    titles = sorted({r['title'] for r in hexes})
    by_source = {s: sum(1 for r in hexes if r['source'] == s) for s in ('photo', 'game', 'correction')}
    by_title = {t: sum(1 for r in hexes if r['title'] == t) for t in titles}
    labels = {t: len({r['label'] for r in hexes if r['title'] == t}) for t in titles}
    things = len({(r['title'], r['hex'], r['label']) for r in hexes})
    baseline = [r for r in hexes if r['source'] == 'photo']
    right = {t: (sum(1 for r in baseline if r['title'] == t and r['read_right']),
                 sum(1 for r in baseline if r['title'] == t)) for t in titles}
    labelled = sum(1 for p in photos if p['labelled'])
    hex_features = '\n'.join(f'  - name: {f}\n    dtype: {d}' for f, d in [
        ('image', 'image'), ('source', 'string'), ('photo', 'string'), ('device', 'string'),
        ('title', 'string'), ('truth', 'string'), ('hex', 'string'), ('label', 'string'),
        ('tile', 'string'), ('rotation', 'int32'), ('colour', 'string'), ('glare', 'float32'),
        ('hex_px', 'int32'), ('facing', 'int32'), ('read_as', 'string'),
        ('read_confidence', 'float32'), ('read_right', 'bool')])
    photo_features = '\n'.join(f'  - name: {f}\n    dtype: {d}' for f, d in [
        ('image', 'image'), ('file', 'string'), ('device', 'string'), ('taken', 'string'),
        ('what', 'string'), ('title', 'string'), ('labelled', 'bool'), ('truth', 'string'),
        ('points', 'string'), ('width', 'int32'), ('height', 'int32'), ('fit', 'image')])
    counts = ', '.join(f'{by_title[t]:,} of {t}' for t in titles)
    reads = '; '.join(f'{t}: {right[t][0]} of {right[t][1]} ({round(100 * right[t][0] / max(1, right[t][1]))}%)'
                      for t in titles)
    return f"""---
pretty_name: 18xx board hexes
# Choose before publishing: the photos are the uploader's, but they show the
# publishers' printed boards and tiles (see Licensing below).
license: unknown
task_categories:
- image-classification
tags:
- board-games
- 18xx
- hexagonal-grid
size_categories:
- 1K<n<10K
configs:
- config_name: hexes
  default: true
  data_files:
  - split: train
    path: hexes/train-*.parquet
- config_name: photos
  data_files:
  - split: train
    path: photos/train-*.parquet
dataset_info:
- config_name: hexes
  features:
{hex_features}
  splits:
  - name: train
    num_examples: {len(hexes)}
- config_name: photos
  features:
{photo_features}
  splits:
  - name: train
    num_examples: {len(photos)}
---

# 18xx board hexes

Photos of real 18xx boards in play -- {', '.join(titles)} -- and {len(hexes):,}
pictures of single hexes cut from them, each labelled with the tile that was
really there (and its turn), or `printed` for the bare map. Made while
building a phone app that photographs an 18xx board, reads its tiles and
tokens, and works out the best routes. For measuring and training tile
recognizers, and for measuring grid matching (placing the map's hexes on a
photo of the board).

## Configs

- **hexes** (default): {len(hexes):,} pictures, 128 x 128 PNG, the hex
  squared up and turned to the board's own frame (the hex fills 0.48 of the
  width, so a little of each neighbour shows). {counts}. By source:
  {by_source['photo']:,} cut from labelled photos, {by_source['game']:,} the
  app's own pictures from saved games whose board is known,
  {by_source['correction']:,} from the app's log of the user's corrections.
- **photos**: all {len(photos)} photos taken (webcam, Nokia C32, iPhone SE),
  {labelled} of them labelled, with where the board's hexes are in each
  (hand-picked centres in `points`, `hex:x,y;...`) and an overlay of the
  placement in `fit`.

```python
from datasets import load_dataset
hexes = load_dataset("<user>/<repo>", "hexes", split="train")
photos = load_dataset("<user>/<repo>", "photos", split="train")
```

## Columns of `hexes`

| column | |
|---|---|
| image | the hex picture |
| source | `photo`, `game` or `correction` |
| photo | the photo's id (for `game` rows, the saved game's) |
| device | `webcam`, `phone` (Nokia C32) or `iphone` |
| title | the game: {', '.join(titles)} |
| truth | which record of the board labels it (`user` for corrections) |
| hex | the map hex, as the game prints it |
| label | `tile@turn`, or `printed`; a turn that looks the same as a lower one is given as the lower one |
| tile, rotation, colour | the label in parts; colour is the tile's (`plain` for the bare map) |
| glare | how washed out the hex was, 0 to 1 |
| hex_px | the hex's width in the photo, in pixels (photo rows) |
| facing | which way the board faced in the photo, degrees (0: from the south edge) |
| read_as, read_confidence, read_right | what the app read: for photo rows, fresh with nothing to go on -- the baseline to beat ({reads}); for game rows, in play; for corrections, before the user put it right |

## Caveats

- Only {things} different things (title, hex, label) among {len(hexes):,}
  pictures, over {', '.join(f'{labels[t]} labels of {t}' for t in titles)}:
  most are the same hexes photographed again in other light and from other
  angles. A random split leaks; split by (title, hex, label), or by photo.
- The photos are of one 1844 game and one 1889 board; most tiles were only
  ever on one hex.
- Corrections lean towards what the app got wrong.
- Some photos show the room around the table.

`extras/` holds the provenance: the manifest (which photos are labelled by
which record, and labels put right), the records of each board, the saved
games, the devices' correction logs, and the data set's own README with the
full story of every label.

## Licensing

The photos were taken by the uploader of games they own, but the boards and
tiles they show are the publishers' printed artwork (1844: Helmut Ohley's
design, published by Lookout; 1889: Yasutaka Ikeda's, published by Grand
Trunk Games -- as tobymao/18xx lists them). Tile definitions come from
tobymao/18xx (MIT). Settle the licence, and whether the artwork's owners
need asking, before publishing.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dataset', default='dataset', help='the data set folder (default: dataset)')
    parser.add_argument('--out', default=None, help='where to write the repository (default: <dataset>/hf)')
    parser.add_argument('--shard-mb', type=int, default=250, help='largest parquet file, roughly, in MB')
    args = parser.parse_args()
    root = Path(args.dataset)
    out = Path(args.out) if args.out else root / 'hf'
    if not (root / 'hexes.csv').exists():
        sys.exit(f'{root}/hexes.csv not found: build the data set first')
    out.mkdir(parents=True, exist_ok=True)
    shard = args.shard_mb * 1024 * 1024

    hexes, hex_schema = hexes_rows(root)
    hex_shards = write_parquet(hexes, hex_schema, ['image'], out / 'hexes', shard, row_group=500)
    photos, photo_schema = photos_rows(root)
    photo_shards = write_parquet(photos, photo_schema, ['image', 'fit'], out / 'photos', shard, row_group=10)
    copy_extras(root, out)
    (out / 'README.md').write_text(card(hexes, photos, hex_shards, photo_shards))
    total = sum(f.stat().st_size for f in out.rglob('*') if f.is_file())
    print(f'{len(hexes)} hex pictures in {hex_shards} file(s), {len(photos)} photos in '
          f'{photo_shards} file(s); {total / 1e6:.0f} MB in {out}')


if __name__ == '__main__':
    main()
