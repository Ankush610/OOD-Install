"""Fail the image build unless every package in /opt/constraints.txt is installed at exactly that version."""
import importlib.metadata as md
bad = []
for line in open("/opt/constraints.txt"):
    name, want = line.strip().split("==")
    try:
        have = md.version(name)
    except md.PackageNotFoundError:
        have = "missing"
    print(f"{'ok ' if have == want else 'BAD'} {name} {have} (SIF {want})")
    bad += [name] if have != want else []
raise SystemExit(f"not the training SIF's versions: {bad}" if bad else 0)
