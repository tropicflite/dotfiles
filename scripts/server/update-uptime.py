#!/usr/bin/env python3
import re
from pathlib import Path

with open('/proc/uptime') as f:
    secs = int(float(f.read().split()[0]))

d, secs = divmod(secs, 86400)
h, secs = divmod(secs, 3600)
m = secs // 60

# Fixed width so the file size stays constant: git's uptime clean filter
# (~/docker/.gitattributes) only keeps `git status` clean if size doesn't change
uptime = f'{d}d {h:02d}h {m:02d}m'

path = Path('/home/matt/docker/homepage/config/services.yaml')
content = path.read_text()
new_content = re.sub(
    r'(  - Server Uptime:\n        icon: [^\n]+\n)        description: [^\n]+',
    lambda m: m.group(1) + f'        description: {uptime}',
    content
)
if new_content != content:
    path.write_text(new_content)
