#!/usr/bin/env python3
"""Write a black-box stub of one module: its header (parameters and ports)
with the body removed. Usage: stub.py <file.sv> <module> > stub.sv"""
import re
import sys

path, name = sys.argv[1], sys.argv[2]
text = open(path).read()
m = re.search(r'^module\s+' + re.escape(name) + r'\b', text, re.M)
if not m:
    sys.exit(f'{name} not in {path}')
end = re.compile(r'^\);', re.M).search(text, m.end())
print('(* black_box *)')
print(text[m.start():end.end()])
print('endmodule')
