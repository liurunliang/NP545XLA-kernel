#!/usr/bin/env python3
"""Print the one verified GRUB configuration member of a standalone EFI."""
import io
from pathlib import Path
import re
import sys
import tarfile

name = 'boot/grub/grub.cfg'
image = Path(sys.argv[1]).read_bytes()
offsets = [m.start() for m in re.finditer(re.escape(name.encode()) + b'\0', image)
           if image[m.start() + 257:m.start() + 262] == b'ustar']
if len(offsets) != 1:
    sys.exit('Expected exactly one GRUB configuration member in the EFI')
with tarfile.open(fileobj=io.BytesIO(image[offsets[0]:]), mode='r:') as archive:
    entry = archive.next()
    if not entry or not entry.isfile() or entry.name != name:
        sys.exit('Invalid GRUB configuration member')
    sys.stdout.buffer.write(archive.extractfile(entry).read())
