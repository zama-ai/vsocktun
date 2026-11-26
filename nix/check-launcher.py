"""Check that a launcher image carries the generic enclave runtime tools."""

import json
import posixpath
import sys
import tarfile


def read_files(archive):
    files = {}
    with tarfile.open(archive) as image:
        manifest = json.load(image.extractfile("manifest.json"))[0]
        for path in manifest["Layers"]:
            with tarfile.open(fileobj=image.extractfile(path), mode="r|") as layer:
                for entry in layer:
                    files[posixpath.normpath("/" + entry.name.lstrip("/"))] = entry
    return files


def resolve(files, path):
    for _ in range(100):
        parts = path.strip("/").split("/")
        for index in range(len(parts)):
            prefix = "/" + "/".join(parts[: index + 1])
            entry = files.get(prefix)
            if entry is not None and (entry.issym() or entry.islnk()):
                target = entry.linkname
                if entry.islnk():
                    target = "/" + target.lstrip("/")
                elif not target.startswith("/"):
                    target = posixpath.join(posixpath.dirname(prefix), target)
                path = posixpath.normpath(posixpath.join(target, *parts[index + 1 :]))
                break
        else:
            return files[path]
    raise AssertionError(f"Symlink loop: {path}")


def check(archive, eif_path):
    files = read_files(archive)
    for binary in (
        "/bin/nitro-cli",
        "/bin/vsocktun",
        "/bin/socat",
        "/bin/ifconfig",
        "/bin/ip",
        "/bin/yq",
        "/bin/dnsproxy",
    ):
        entry = resolve(files, binary)
        assert entry.isfile() and entry.mode & 0o111, binary
    entry = resolve(files, eif_path)
    assert entry.isfile(), eif_path
    print(f"launcher image: tools and {eif_path} passed")


if __name__ == "__main__":
    check(*sys.argv[1:])
