#!/usr/bin/env python3
"""Build and inspect byte-preserving jimage 1.1 runtime module images.

The writer is the exact pinned OpenJDK Mobile writer, compiled in a temporary
directory with JDK 21+. Class files are opaque bytes: the build JDK does not need
to understand the runtime's class-file version. Inspection is independent Python
and checks image indexes, perfect hashes, directory/package trees, and resources.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
WRITER = HERE / "jimage-writer"
PIN = "c1ed06aaef34c8dccf71e236d1ffa20918a77cfb"
LOCK = json.loads((HERE / "runtime-lock.json").read_bytes())
MODULES = frozenset(LOCK["requiredModules"])
if LOCK["openjdkMobile"]["commit"] != PIN or len(MODULES) != 13:
    raise ValueError("Jimage writer source pin/module set differs from runtime-lock.json")
PROBES = ("java.base/java/lang/Object.class", "java.base/java/lang/String.class",
          "java.base/java/lang/Class.class", "java.xml/org/w3c/dom/Node.class",
          "java.xml/javax/xml/parsers/DocumentBuilderFactory.class",
          "java.desktop/java/beans/Introspector.class",
          "java.net.http/java/net/http/HttpClient.class", "java.sql/java/sql/Connection.class",
          "java.desktop/java/awt/Component.class", "jdk.unsupported/sun/misc/Unsafe.class")
MAX_IMAGE_BYTES = 268435456


def require(condition, message):
    if not condition:
        raise ValueError(message)


def _sha(raw):
    return hashlib.sha256(raw).hexdigest()


def _file_sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _aggregate(resources):
    return _sha(json.dumps(resources, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=True).encode("ascii"))


def _safe_relative(name):
    require(name and not name.startswith("/") and "\\" not in name and ":" not in name
            and all(part not in ("", ".", "..") for part in name.split("/"))
            and not any(ord(c) < 32 or ord(c) == 127 for c in name), "Unsafe module resource path")


def _mutf8(raw):
    text = raw.replace(b"\xc0\x80", b"\x00").decode("utf-8", "surrogatepass")
    return text.encode("utf-16-le", "surrogatepass").decode("utf-16-le")


def _hash_name(name, seed=0x01000193):
    # ImageStringsReader hashes the modified-UTF8 encoding of Java UTF16 units.
    units = name.encode("utf-16-be")
    for offset in range(0, len(units), 2):
        unit = (units[offset] << 8) | units[offset + 1]
        if unit == 0:
            encoded = (0xC0, 0x80)
        elif unit <= 0x7F:
            encoded = (unit,)
        elif unit <= 0x7FF:
            encoded = (0xC0 | (unit >> 6), 0x80 | (unit & 63))
        else:
            encoded = (0xE0 | (unit >> 12), 0x80 | ((unit >> 6) & 63), 0x80 | (unit & 63))
        for byte in encoded:
            seed = ((seed * 0x01000193) ^ byte) & 0xFFFFFFFF
    return seed & 0x7FFFFFFF


class _Image:
    def __init__(self, path):
        self.path = Path(path)
        require(self.path.is_file() and not self.path.is_symlink(), "Module image must be a regular file")
        require(28 <= self.path.stat().st_size <= MAX_IMAGE_BYTES, "Module image exceeds its size budget")
        self.raw = self.path.read_bytes()
        header = struct.unpack("<7I", self.raw[:28])
        magic, version, flags, count, length, locations_size, strings_size = header
        require(magic == 0xCAFEDADA and version == 0x00010001 and flags == 0,
                "Expected pinned little-endian jimage version 1.1 with flags=0")
        require(0 < count <= length <= 250000 and locations_size > 0 and strings_size > 23,
                "Invalid jimage index dimensions")
        self.index_size = 28 + length * 8 + locations_size + strings_size
        require(self.index_size <= len(self.raw), "Jimage index exceeds the file")
        self.redirect = struct.unpack_from("<" + "i" * length, self.raw, 28)
        offsets = struct.unpack_from("<" + "I" * length, self.raw, 28 + length * 4)
        start = 28 + length * 8
        self.locations = self.raw[start:start + locations_size]
        self.strings = self.raw[start + locations_size:self.index_size]
        require(self.strings.startswith(b"\x00class\x00modules\x00packages\x00"),
                "Pinned jimage 1.1 reserved string offsets are missing")
        self.by_offset = {}
        self.by_name = {}
        self.resources = {}
        ranges = []
        for offset in offsets:
            if not offset:
                continue
            require(offset not in self.by_offset and offset < locations_size, "Invalid/duplicate location offset")
            attrs, position = [0] * 9, offset
            previous = 0
            while True:
                require(position < locations_size, "Unterminated jimage location")
                tag = self.locations[position]
                position += 1
                if tag <= 7:
                    require(tag == 0, "Unexpected location terminator")
                    break
                kind, size = tag >> 3, (tag & 7) + 1
                require(previous < kind < 9 and position + size <= locations_size,
                        "Invalid jimage location attributes")
                attrs[kind] = int.from_bytes(self.locations[position:position + size], "big")
                previous, position = kind, position + size
            module, parent, base, extension = (self.string(attrs[i]) for i in range(1, 5))
            name = (("/" + module + "/") if module else "") + ((parent + "/") if parent else "") + base
            if extension:
                name += "." + extension
            require(name not in self.by_name and attrs[6] == 0 and attrs[8] == 0,
                    "Duplicate, compressed, or preview-only resource is unsupported")
            begin, end = self.index_size + attrs[5], self.index_size + attrs[5] + attrs[7]
            require(self.index_size <= begin <= end <= len(self.raw), "Jimage resource range exceeds the file")
            row = {"name": name, "attrs": attrs, "begin": begin, "end": end, "location": offset}
            self.by_offset[offset] = row
            self.by_name[name] = row
            ranges.append((begin, end))
            if module not in ("modules", "packages") and name not in ("/modules", "/packages"):
                require(module in MODULES, "Unexpected image module")
                relative = name.removeprefix("/")
                _safe_relative(relative)
                if relative.endswith(".class"):
                    require(self.raw[begin:begin + 8] == b"\xca\xfe\xba\xbe\x00\x00\x00H",
                            "Unsupported preview or non-pinned class in the module image")
                self.resources[relative] = {"bytes": attrs[7], "sha256": _sha(self.raw[begin:end])}
        require(len(self.by_offset) == count, "Resource-count/index mismatch")
        last_end = self.index_size
        for begin, end in sorted(ranges):
            require(begin == last_end, "Image content has an overlap or unindexed gap")
            last_end = end
        # OpenJDK ImageResourcesTree emits the synthetic root's two child
        # offsets last. The synthetic root itself has no index location.
        roots = (self.by_name.get("/modules"), self.by_name.get("/packages"))
        require(all(roots) and len(self.raw) - last_end == 8
                and struct.unpack_from("<2I", self.raw, last_end)
                == tuple(row["location"] for row in roots),
                "Invalid synthetic-root trailer or unindexed trailing image bytes")
        for name, row in self.by_name.items():
            redirect = self.redirect[_hash_name(name) % length]
            slot = -redirect - 1 if redirect < 0 else _hash_name(name, redirect) % length if redirect else -1
            require(0 <= slot < length and offsets[slot] == row["location"], "Perfect-hash lookup mismatch")
        self._trees()

    def string(self, offset):
        require(0 <= offset < len(self.strings), "String offset exceeds the image string table")
        end = self.strings.find(b"\x00", offset)
        require(end >= 0 and (offset == 0 or self.strings[offset - 1] == 0), "Invalid string-table reference")
        return _mutf8(self.strings[offset:end])

    def content(self, row):
        return self.raw[row["begin"]:row["end"]]

    def _trees(self):
        require("/modules" in self.by_name and "/packages" in self.by_name, "Standard image trees are missing")
        reached = set()

        def walk(name):
            require(name not in reached, "Image tree has a cycle or repeated child")
            reached.add(name)
            row = self.by_name[name]
            raw = self.content(row)
            require(len(raw) % 4 == 0, "Directory-tree data is not aligned")
            children = []
            for offset in struct.unpack("<" + "I" * (len(raw) // 4), raw):
                require(offset in self.by_offset, "Directory-tree location reference is invalid")
                child = self.by_offset[offset]["name"]
                if child.startswith("/modules/") or child.startswith("/packages/"):
                    canonical = child
                else:
                    canonical = "/modules" + child
                require(canonical.rsplit("/", 1)[0] == name, "Directory-tree child has the wrong parent")
                children.append(canonical)
                if child.startswith("/modules/"):
                    walk(child)
                elif child.startswith("/packages/"):
                    reached.add(child)
                    links = self.content(self.by_name[child])
                    require(len(links) % 8 == 0, "Package links are not aligned")
                    for flags, module_offset in struct.iter_unpack("<2I", links):
                        require(flags in (2, 6) and self.string(module_offset) in MODULES,
                                "Invalid jimage 1.1 package-module link")
                else:
                    require(child.removeprefix("/") in self.resources, "Unknown module-tree leaf")
                    reached.add(child)
            require(len(children) == len(set(children)), "Repeated directory-tree child")

        walk("/modules")
        walk("/packages")
        require(reached == set(self.by_name), "Unreachable index entries in the standard resource trees")

    def report(self):
        modules = sorted({name.split("/", 1)[0] for name in self.resources})
        require(set(modules) == MODULES, "Expected exactly the thirteen pinned runtime modules")
        descriptors = [module + "/module-info.class" for module in modules]
        require(all(name in self.resources for name in (*PROBES, *descriptors)), "Required image probes are missing")
        for name in (*PROBES, *descriptors):
            raw = self.content(self.by_name["/" + name])
            require(raw.startswith(b"\xca\xfe\xba\xbe\x00\x00\x00H"),
                    "Required probe is not a non-preview pinned major-72 class")
        return {"layout": "jimage", "version": "1.1", "byteOrder": "little-endian",
                "bytes": len(self.raw), "sha256": _sha(self.raw), "moduleCount": len(modules),
                "modules": modules, "resourceCount": len(self.resources),
                "resourceBytes": sum(item["bytes"] for item in self.resources.values()),
                "resourceSHA256Aggregate": _aggregate(self.resources),
                "moduleDescriptorCount": len(descriptors), "requiredProbesVerified": True,
                "indexResourceCount": len(self.by_name), "indexBytes": self.index_size,
                "perfectHashLookupsVerified": True, "standardResourceTreesVerified": True,
                "probes": {name: self.resources[name] for name in (*PROBES, *descriptors)},
                "resourcePaths": sorted(self.resources)}


def inspect(image):
    """Validate a pinned uncompressed little-endian 1.1 image without running Java."""
    return _Image(image).report()


def _java_tools(java_home):
    root = java_home or os.environ.get("JAVA_HOME")
    if root:
        java, javac = (Path(root) / "bin" / (name + (".exe" if os.name == "nt" else ""))
                       for name in ("java", "javac"))
    else:
        java, javac = (Path(shutil.which(name) or "") for name in ("java", "javac"))
    require(java.is_file() and javac.is_file(), "JDK 21+ java and javac are required to build jimage")
    version = subprocess.run([str(javac), "-version"], capture_output=True, text=True,
                             timeout=15, check=False)
    text = (version.stdout + version.stderr).strip()
    match = re.search(r"javac (\d+)", text)
    require(version.returncode == 0 and match is not None and int(match[1]) >= 21,
            "JDK 21+ is required to build jimage; selected javac reports: " + text)
    return java, javac, text


def create(modules, output, java_home=None):
    """Pack an exploded modules directory without changing any resource bytes."""
    modules, output = Path(modules).absolute(), Path(output).absolute()
    require(modules.is_dir() and not modules.is_symlink(), "Exploded module directory is absent")
    require(not output.is_relative_to(modules), "Output must stay outside the unmodified source module directory")
    require(not output.exists() and output.parent.is_dir(), "Output must be a new file in an existing directory")
    resources = {}
    for path in sorted(modules.rglob("*")):
        require(not path.is_symlink(), "Module resources must not be symlinks")
        if not path.is_file():
            continue
        name = path.relative_to(modules).as_posix()
        _safe_relative(name)
        require(name.split("/", 1)[0] in MODULES and "/" in name, "Unexpected source module path")
        if name.endswith(".class"):
            with path.open("rb") as stream:
                require(stream.read(8) == b"\xca\xfe\xba\xbe\x00\x00\x00H",
                        "Unsupported preview or non-pinned class in source modules")
        resources[name] = {"bytes": path.stat().st_size, "sha256": _file_sha(path)}
    require({name.split("/", 1)[0] for name in resources} == MODULES, "Expected exactly thirteen source modules")
    java, javac, java_version = _java_tools(java_home)
    provenance = json.loads((WRITER / "source-provenance.json").read_bytes())
    require(provenance.get("sourceCommit") == PIN, "Writer source pin differs")
    source_facts = []
    for row in provenance["files"]:
        path = WRITER / row["localPath"]
        raw = path.read_bytes()
        git_blob = hashlib.sha1(b"blob " + str(len(raw)).encode("ascii") + b"\x00" + raw).hexdigest()
        require(git_blob == row["gitBlob"], "Vendored writer source differs from its pinned Git blob")
        source_facts.append({**row, "sha256": _sha(raw)})
    commands = []
    with tempfile.TemporaryDirectory(prefix="yuedu-jimage-") as temporary:
        work = Path(temporary)
        base_out, writer_out, helper_out = (work / name for name in ("base", "writer", "helper"))
        base_sources = sorted((WRITER / "java.base").rglob("*.java"))
        writer_sources = sorted((WRITER / "jdk.jlink").rglob("*.java"))
        require(len(base_sources) == 6 and len(writer_sources) == 5,
                "Expected the exact six-core/five-writer pinned source set")
        require({row["localPath"] for row in provenance["files"]}
                == {path.relative_to(WRITER).as_posix() for path in (*base_sources, *writer_sources)} | {"LICENSE"},
                "Pinned source manifest and compiled source set differ")

        def run(args):
            completed = subprocess.run([str(arg) for arg in args], capture_output=True, text=True,
                                       timeout=120, check=False)
            require(completed.returncode == 0, "Pinned jimage tool failed: " + completed.stderr[-4000:])
            commands.append({"tool": str(args[0]), "exitCode": completed.returncode})

        run([javac, "--patch-module", "java.base=" + str(WRITER / "java.base"),
             "-d", base_out, *base_sources])
        run([javac, "--patch-module", "java.base=" + str(base_out), "--patch-module",
             "jdk.jlink=" + str(WRITER / "jdk.jlink"), "-d", writer_out, *writer_sources])
        flags = ["--patch-module", "java.base=" + str(base_out), "--patch-module",
                 "jdk.jlink=" + str(writer_out), "--add-modules", "jdk.jlink", "--add-exports",
                 "jdk.jlink/jdk.tools.jlink.internal=ALL-UNNAMED"]
        run([javac, *flags, "-d", helper_out, WRITER / "BuildJimage.java"])
        run([java, *flags, "-cp", helper_out, "BuildJimage", modules, output])
    actual = _Image(output)
    require(actual.resources == resources, "Image resource set, sizes or hashes differ from the source")
    # Re-read the source after construction to catch accidental/concurrent mutations.
    for name, fact in resources.items():
        path = modules / name
        require(path.is_file() and path.stat().st_size == fact["bytes"] and _file_sha(path) == fact["sha256"],
                "Exploded module resource changed during conversion")
        require(actual.content(actual.by_name["/" + name]) == path.read_bytes(),
                "Image resource bytes differ from the unchanged source resource")
    report = actual.report()
    report.update(allResourceBytesPreserved=True, sourceTreeSHA256Aggregate=_aggregate(resources),
                  buildToolSources={"repository": provenance["repository"], "commit": PIN,
                                    "manifestSHA256": _file_sha(WRITER / "source-provenance.json"),
                                    "helperSHA256": _file_sha(WRITER / "BuildJimage.java"),
                                    "files": source_facts},
                  buildJDKVersion=java_version, buildCommands=commands, classFilesRecompiled=False,
                  nativeRuntimeRecompiled=False, nativeExecutionVerified=False)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    convert = commands.add_parser("create")
    convert.add_argument("--modules", type=Path, required=True)
    convert.add_argument("--output", type=Path, required=True)
    convert.add_argument("--java-home", type=Path)
    check = commands.add_parser("inspect")
    check.add_argument("image", type=Path)
    args = parser.parse_args()
    report = create(args.modules, args.output, args.java_home) if args.command == "create" else inspect(args.image)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
