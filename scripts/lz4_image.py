#!/usr/bin/env python3
"""Compress the RPi5 provisioning image for embedding (GitHub issue #1218).

The RPi5 lane loads the kernel over SWD at about 187 KiB/s, and the 6 MiB
ext2 image the board writes to its USB stick was most of those bytes. The
kernel embeds this file instead and expands it one 64 KiB chunk at a time
(kernel/lib/lz4_image.tkb), so the load carries the compressed bytes only.

Container (all integers little-endian):

    "TKZ1"  u32 block_size  u32 chunk_blocks  u32 chunk_count
    per chunk:  u64 present  u32 coded_len  coded_len bytes

`present` has bit i set when block i of the chunk holds a nonzero byte:
the zero-block elision stage. The present blocks, concatenated in order,
are one LZ4 block (reference block format, no frame) of coded_len bytes;
a chunk with no present block has coded_len 0. Chunks are independent, so
the kernel needs only a chunk-sized output region. Zero bytes after the
last chunk are padding: pack-pair pads two containers to one length so a
built kernel can carry either (the RPi5 shell kernel is the main one with
its container replaced in place, scripts/patch_embedded_image.py).

Usage:
    lz4_image.py pack IMAGE OUT        compress, then decode OUT with the
                                       decoder below and compare to IMAGE
    lz4_image.py pack-pair A B OUTA OUTB
                                       pack both, pad to one length, check
    lz4_image.py fixture DIR           the linux_user/lz4 test's inputs:
                                       image.bin, image.tkz, text.bin,
                                       text.lz4
    lz4_image.py self-test             (what langcheck runs)
Exit code 0 on success.
"""

import struct
import sys

from pass_line import report_pass

MAGIC = b"TKZ1"
BLOCK_SIZE = 1024
CHUNK_BLOCKS = 64
MIN_MATCH = 4
LAST_LITERALS = 5
MATCH_FIND_LIMIT = 12
MAX_OFFSET = 65535


def _length_bytes(length):
    out = bytearray()
    while length >= 255:
        out.append(255)
        length -= 255
    out.append(length)
    return out


def _sequence(out, literals, offset, match_length):
    lit_nibble = min(len(literals), 15)
    match_nibble = 0 if match_length == 0 else min(match_length - MIN_MATCH, 15)
    out.append((lit_nibble << 4) | match_nibble)
    if lit_nibble == 15:
        out += _length_bytes(len(literals) - 15)
    out += literals
    if match_length == 0:
        return
    out += struct.pack("<H", offset)
    if match_nibble == 15:
        out += _length_bytes(match_length - MIN_MATCH - 15)


def compress(data):
    """Greedy LZ4 with an exact 4-byte dictionary (better ratio than the
    kernel's 4096-entry hash, same format)."""
    data = bytes(data)
    n = len(data)
    out = bytearray()
    anchor = 0
    if n > MATCH_FIND_LIMIT:
        find_limit = n - MATCH_FIND_LIMIT
        match_limit = n - LAST_LITERALS
        last = {}
        ip = 0
        while ip < find_limit:
            key = data[ip:ip + 4]
            ref = last.get(key)
            last[key] = ip
            if ref is not None and ip - ref <= MAX_OFFSET:
                length = MIN_MATCH
                while ip + length < match_limit and data[ip + length] == data[ref + length]:
                    length += 1
                _sequence(out, data[anchor:ip], ip - ref, length)
                # Index the positions the match covered, cheaply: the first
                # few and the last, which is where the next matches start.
                for p in range(ip + 1, min(ip + length, find_limit), 1 if length < 64 else 7):
                    last[data[p:p + 4]] = p
                ip += length
                anchor = ip
            else:
                ip += 1
    _sequence(out, data[anchor:], 0, 0)
    return bytes(out)


class Invalid(ValueError):
    pass


def _read_length(src, ip):
    total = 0
    while True:
        if ip >= len(src):
            raise Invalid("length runs past the input")
        value = src[ip]
        ip += 1
        total += value
        if value != 255:
            return total, ip


def decompress(src, capacity):
    """Reference-format decode, refusing what the kernel's decoder refuses."""
    out = bytearray()
    ip = 0
    if not src:
        return bytes(out)
    while ip < len(src):
        token = src[ip]
        ip += 1
        literals = token >> 4
        if literals == 15:
            more, ip = _read_length(src, ip)
            literals += more
        if literals > len(src) - ip or len(out) + literals > capacity:
            raise Invalid("literals past an end")
        out += src[ip:ip + literals]
        ip += literals
        if ip == len(src):
            return bytes(out)
        if ip + 2 > len(src):
            raise Invalid("offset past the input")
        offset = src[ip] | (src[ip + 1] << 8)
        ip += 2
        if offset == 0 or offset > len(out):
            raise Invalid("offset outside the output")
        length = (token & 15) + MIN_MATCH
        if token & 15 == 15:
            more, ip = _read_length(src, ip)
            length += more
        if len(out) + length > capacity:
            raise Invalid("match past the output")
        start = len(out) - offset
        for k in range(length):
            out.append(out[start + k])
    raise Invalid("no final literals")


def pack(image):
    chunk_bytes = BLOCK_SIZE * CHUNK_BLOCKS
    if len(image) % chunk_bytes != 0:
        raise ValueError(f"image length {len(image)} is not a multiple of {chunk_bytes}")
    chunks = len(image) // chunk_bytes
    out = bytearray(MAGIC + struct.pack("<III", BLOCK_SIZE, CHUNK_BLOCKS, chunks))
    zero = bytes(BLOCK_SIZE)
    for c in range(chunks):
        present = 0
        kept = bytearray()
        for b in range(CHUNK_BLOCKS):
            start = c * chunk_bytes + b * BLOCK_SIZE
            block = image[start:start + BLOCK_SIZE]
            if block != zero:
                present |= 1 << b
                kept += block
        coded = compress(kept) if kept else b""
        out += struct.pack("<QI", present, len(coded)) + coded
    return bytes(out)


def unpack(container):
    if container[:4] != MAGIC:
        raise Invalid("no TKZ1 magic")
    block_size, chunk_blocks, chunks = struct.unpack_from("<III", container, 4)
    if (block_size, chunk_blocks) != (BLOCK_SIZE, CHUNK_BLOCKS):
        raise Invalid("unexpected geometry")
    at = 16
    image = bytearray()
    for _ in range(chunks):
        present, coded_len = struct.unpack_from("<QI", container, at)
        at += 12
        coded = container[at:at + coded_len]
        if len(coded) != coded_len:
            raise Invalid("chunk past the container")
        at += coded_len
        count = bin(present).count("1")
        kept = decompress(coded, count * BLOCK_SIZE) if count else b""
        if len(kept) != count * BLOCK_SIZE:
            raise Invalid("chunk decodes to the wrong length")
        k = 0
        for b in range(CHUNK_BLOCKS):
            if present >> b & 1:
                image += kept[k * BLOCK_SIZE:(k + 1) * BLOCK_SIZE]
                k += 1
            else:
                image += bytes(BLOCK_SIZE)
    if any(container[at:]):
        raise Invalid("nonzero bytes after the last chunk")
    return bytes(image)


def self_test():
    samples = [b"", b"a", b"abcdefghijkl", b"abcdefghijklm" * 3, bytes(5000),
               bytes(range(256)) * 40, b"x" * 70000,
               bytes((i * 7919 >> 3) & 255 for i in range(9000))]
    for sample in samples:
        coded = compress(sample)
        assert decompress(coded, len(sample)) == sample, len(sample)
    # The reference encoding of 20 'a': one literal, then a 19-byte match at
    # offset 1 (token 0x1F, match extra 0), then five literals.
    assert decompress(bytes([0x1F, 0x61, 1, 0, 0, 0x50]) + b"aaaaa", 64) == b"a" * 25
    for bad in (bytes([0x10, 0x61, 0, 0, 0x00]), bytes([0x10, 0x61, 2, 0, 0x00]),
                bytes([0xF0]), bytes([0x20, 0x61])):
        try:
            decompress(bad, 64)
        except Invalid:
            continue
        raise AssertionError(f"accepted {bad!r}")
    image = bytearray(BLOCK_SIZE * CHUNK_BLOCKS * 2)
    image[5 * BLOCK_SIZE:6 * BLOCK_SIZE] = b"\x01" * BLOCK_SIZE
    image[70 * BLOCK_SIZE + 3] = 9
    container = pack(bytes(image))
    assert unpack(container) == bytes(image)
    assert unpack(container + bytes(3)) == bytes(image)
    try:
        unpack(container + b"\x01")
    except Invalid:
        pass
    else:
        raise AssertionError("accepted a nonzero byte after the last chunk")
    assert struct.unpack_from("<Q", container, 16)[0] == 1 << 5
    report_pass("lz4-image", "self-test: block round trips, a reference "
                "vector, four refused blocks, a two-chunk container",
                samples=len(samples))


def fixture_image():
    """Three chunks: zero blocks between data, a text run, bytes that do not
    compress, a block that is zero but for its last byte, and a chunk that
    is all zero."""
    chunk = BLOCK_SIZE * CHUNK_BLOCKS
    image = bytearray(chunk * 3)
    text = b"Takibi provisions the stick from this image. " * 40
    image[BLOCK_SIZE:BLOCK_SIZE + len(text)] = text
    state = 12345
    for i in range(8 * BLOCK_SIZE):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        image[20 * BLOCK_SIZE + i] = state >> 16 & 255
    image[63 * BLOCK_SIZE + BLOCK_SIZE - 1] = 0xA5
    image[chunk + 5 * BLOCK_SIZE:chunk + 9 * BLOCK_SIZE] = bytes([0x5A]) * (4 * BLOCK_SIZE)
    return bytes(image), text


def write_fixture(directory):
    import os
    image, text = fixture_image()
    files = {"image.bin": image, "image.tkz": pack(image),
             "text.bin": text, "text.lz4": compress(text)}
    os.makedirs(directory, exist_ok=True)
    for name, data in files.items():
        with open(os.path.join(directory, name), "wb") as handle:
            handle.write(data)


def main(argv):
    if len(argv) == 3 and argv[1] == "fixture":
        write_fixture(argv[2])
        return 0
    if len(argv) == 2 and argv[1] == "self-test":
        self_test()
        return 0
    if (len(argv) == 4 and argv[1] == "pack") or (len(argv) == 6 and argv[1] == "pack-pair"):
        count = (len(argv) - 2) // 2
        images = []
        for path in argv[2:2 + count]:
            with open(path, "rb") as handle:
                images.append(handle.read())
        outs = [pack(image) for image in images]
        width = max(len(out) for out in outs)
        outs = [out + bytes(width - len(out)) for out in outs]
        for path, image, out in zip(argv[2:2 + count], images, outs):
            if unpack(out) != image:
                print(f"FAIL lz4-image: {path} does not decode back", file=sys.stderr)
                return 1
        for path, out in zip(argv[2 + count:], outs):
            with open(path, "wb") as handle:
                handle.write(out)
        report_pass("lz4-image", ", ".join(
            f"{path}: {len(image)} -> {width} bytes"
            for path, image in zip(argv[2:2 + count], images)),
            bytes=sum(len(image) for image in images))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
