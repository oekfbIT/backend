#!/usr/bin/env python3
"""Export literal Swift catalog defaults as MongoDB-importable template documents."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/App/Services/EmailTemplateCatalog.swift').read_text()
pattern = r'\.init\(key: "([^"]+)", subject: "([^"]+)", html: #"""\n(.*?)\n\s*"""#, variables: \[(.*?)\]\)'
records = []
for key, subject, html, variables in re.findall(pattern, source, re.S):
    # Swift multiline literals strip the closing delimiter's eight-space indent.
    body = '\n'.join(line[8:] if line.startswith('        ') else line for line in html.splitlines())
    records.append({'_id': key, 'subject': subject, 'html': body})
if len(records) != source.count('.init(key:'):
    raise SystemExit('Catalog format changed; refusing to produce an incomplete export.')
target = root / 'docs/email-templates'
target.mkdir(parents=True, exist_ok=True)
(target / 'defaults.json').write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n')
print(f'Exported {len(records)} catalog templates to {target / "defaults.json"}')
