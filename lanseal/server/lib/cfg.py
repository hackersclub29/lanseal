#!/usr/bin/env python3
"""cfg.py FILE dotted.key -> print a scalar, or one list item per line."""
import sys
import yaml

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: cfg.py FILE dotted.key")
    with open(sys.argv[1], encoding="utf-8") as fh:
        node = yaml.safe_load(fh)
    for part in sys.argv[2].split("."):
        if not isinstance(node, dict) or part not in node:
            sys.exit(f"cfg.py: missing key '{sys.argv[2]}'")
        node = node[part]
    if isinstance(node, list):
        print("\n".join(str(x) for x in node))
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(node)

if __name__ == "__main__":
    main()
