#!/usr/bin/env python3
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Builds the tar and zip fixtures for tests/sh/archive.sh. Test-only, standard library only.

Usage: make_archives.py OUTDIR

Writes into OUTDIR (created when missing); nothing is extracted and nothing outside OUTDIR is touched.
The unsafe archives carry hostile entry names as plain data; they are only ever listed, never extracted.

tar.gz: clean, dotdot, dotdot-mid, abs, symlink (to /etc/passwd), symlink-rel (../../x), symlink-deep
        (a/b/link -> ../../../x), hardlink (target /etc/passwd), hardlink-rel (../x), symchain (a link
        to . followed by an entry below it)
zip:    notype-evil, notype-ok (no file-type bits), spacel (a name holding ' l '), empty, notzip, mismatch
        (entry count disagrees with the header), clean, dotdot, dotdot-mid, abs, backslash, drive, symlink, exec (execute-bit entries under the
        Ghidra top directory)
"""

import gzip
import io
import os
import stat
import struct
import sys
import tarfile
import zipfile

TOP = "ghidra_12.1.4_PUBLIC"


def tar_add(tf, name, data=b"x", kind=tarfile.REGTYPE, link="", mode=0o644):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = mode
    info.mtime = 1767225600
    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
        info.linkname = link
        info.size = 0
        tf.addfile(info)
    elif kind == tarfile.DIRTYPE:
        info.mode = 0o755
        tf.addfile(info)
    else:
        info.size = len(data)
        tf.addfile(info, io.BytesIO(data))


def make_tar(path, entries):
    # mtime=0 and an empty stored file name make the gzip layer byte-for-byte reproducible
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tf:
                for entry in entries:
                    tar_add(tf, *entry)


def zip_add(zf, name, data=b"x", mode=0o100644):
    info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = (mode & 0xFFFF) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(info, data)


def make_zip(path, entries):
    with zipfile.ZipFile(path, "w") as zf:
        for entry in entries:
            zip_add(zf, *entry)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    S = tarfile.SYMTYPE
    L = tarfile.LNKTYPE
    D = tarfile.DIRTYPE
    make_tar(
        os.path.join(out, "clean.tar.gz"),
        [
            ("top", b"", D),
            ("top/bin", b"", D),
            ("top/bin/java", b"java", tarfile.REGTYPE, "", 0o755),
            ("top/file with spaces.txt",),
            ("top/dir with space", b"", D),
            ("top/dir with space/inner file.txt",),
            ("top/lib", b"", D),
            ("top/lib/libjli.so",),
            ("top/bin/libjli.so", b"", S, "../lib/libjli.so"),
            ("top/lib/alias", b"", S, "libjli.so"),
            ("top/hard", b"", L, "top/lib/libjli.so"),
        ],
    )
    make_tar(os.path.join(out, "dotdot.tar.gz"), [("top/ok.txt",), ("../evil.txt",)])
    make_tar(os.path.join(out, "dotdot-mid.tar.gz"), [("top/a/../../b",)])
    make_tar(os.path.join(out, "abs.tar.gz"), [("top/ok.txt",), ("/etc/evil.txt",)])
    make_tar(os.path.join(out, "symlink.tar.gz"), [("top/ok.txt",), ("top/passwd", b"", S, "/etc/passwd")])
    make_tar(os.path.join(out, "symlink-rel.tar.gz"), [("link", b"", S, "../../x")])
    make_tar(os.path.join(out, "symlink-deep.tar.gz"), [("a/b/link", b"", S, "../../../x")])
    make_tar(os.path.join(out, "hardlink.tar.gz"), [("top/hl", b"", L, "/etc/passwd")])
    make_tar(os.path.join(out, "hardlink-rel.tar.gz"), [("top/hl", b"", L, "../x")])
    make_tar(
        os.path.join(out, "symchain.tar.gz"),
        [("d", b"", S, "."), ("d/ln", b"", S, "../x")],
    )

    make_zip(
        os.path.join(out, "clean.zip"),
        [
            (TOP + "/", b"", 0o040755),
            (TOP + "/ok.txt",),
            (TOP + "/dir with space/inner file.txt",),
        ],
    )
    make_zip(os.path.join(out, "dotdot.zip"), [(TOP + "/ok.txt",), ("../evil.txt",)])
    make_zip(os.path.join(out, "dotdot-mid.zip"), [("a/../../b",)])
    make_zip(os.path.join(out, "abs.zip"), [("/etc/evil.txt",)])
    make_zip(os.path.join(out, "backslash.zip"), [("..\\evil.txt",)])
    make_zip(os.path.join(out, "drive.zip"), [("C:\\evil.txt",)])
    make_zip(os.path.join(out, "symlink.zip"), [("passwd", b"/etc/passwd", stat.S_IFLNK | 0o777)])
    make_zip(
        os.path.join(out, "exec.zip"),
        [
            (TOP + "/ghidraRun", b"#!/bin/sh\n", 0o100755),
            (TOP + "/support/analyzeHeadless", b"#!/bin/sh\n", 0o100644),
            (TOP + "/support/launch.properties", b"a=b\n", 0o100644),
            (TOP + "/Ghidra/Features/Decompiler/os/linux_x86_64/decompile", b"ELF", 0o100644),
            (TOP + "/plain.txt", b"t", 0o100644),
        ],
    )


def make_odd_zips(out):
    """Zips whose records unzip prints with no file-type bit (?rw-------), and unusable archives."""
    make_tar(os.path.join(out, "empty.tar.gz"), [])
    make_zip(os.path.join(out, "notype-evil.zip"), [("../../evil", b"x", 0)])
    make_zip(os.path.join(out, "notype-ok.zip"), [(TOP + "/ok.txt", b"x", 0)])
    make_zip(os.path.join(out, "spacel.zip"), [("dir/a l b", b"x", 0o100644), ("dir/c", b"x", 0o100644)])
    with zipfile.ZipFile(os.path.join(out, "empty.zip"), "w"):
        pass
    with open(os.path.join(out, "notzip.zip"), "wb") as f:
        f.write(b"this is not a zip file\n")
    # central directory says 1 entry, holds 2: the listed count must not match the header
    make_zip(os.path.join(out, "two.zip"), [("a", b"1", 0o100644), ("../../evil", b"2", 0o100644)])
    with open(os.path.join(out, "two.zip"), "rb") as f:
        raw = bytearray(f.read())
    eocd = raw.rfind(b"PK\x05\x06")
    struct.pack_into("<HH", raw, eocd + 8, 1, 1)
    with open(os.path.join(out, "mismatch.zip"), "wb") as f:
        f.write(raw)
    os.remove(os.path.join(out, "two.zip"))


if __name__ == "__main__":
    main()
    make_odd_zips(sys.argv[1])
