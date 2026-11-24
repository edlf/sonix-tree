#!/usr/bin/env python3
"""Builds the 1 KiB burner partition table that sits at 0x5800 in the uboot
partition, from a text file (see r1.txt).

    mkparttable.py TABLE.txt OUT.bin

One line per partition: name, offset, size, manager (mtd or ubi) and,
optionally, mask_flags. Numbers in decimal or 0x hex; # starts a comment.

Layout, as the SPL and U-Boot read it (uboot/drivers/usb/gadget/f_fastboot.c,
struct sfc_flash_partition): "nand", the entry count, then 48-byte entries
of name[32], size, offset, mask_flags, manager_mode, all little endian; the
rest of the 1 KiB is 0xff.
"""
import struct, sys

TABLE_SIZE = 0x400
HEADER = 8
ENTRY = 48
MAX_ENTRIES = (TABLE_SIZE - HEADER) // ENTRY
MANAGERS = {"mtd": 0, "ubi": 1}


def fail(path, line, msg):
	sys.exit(f"{path}:{line}: {msg}")


def parse(path):
	parts = []
	for n, raw in enumerate(open(path), 1):
		words = raw.split("#", 1)[0].split()
		if not words:
			continue
		if len(words) not in (4, 5):
			fail(path, n, "expected: name offset size manager [mask_flags]")
		name, off, size, mgr = words[:4]
		try:
			off, size = int(off, 0), int(size, 0)
			mask = int(words[4], 0) if len(words) == 5 else 0
		except ValueError:
			fail(path, n, "offset, size and mask_flags must be numbers")
		if len(name.encode()) > 31:
			fail(path, n, f"name '{name}' longer than 31 bytes")
		if mgr not in MANAGERS:
			fail(path, n, f"manager must be one of {', '.join(MANAGERS)}")
		if size <= 0:
			fail(path, n, "size must be above 0")
		parts.append((n, name, off, size, mask, MANAGERS[mgr]))
	return parts


def check(path, parts):
	if not 1 <= len(parts) <= MAX_ENTRIES:
		sys.exit(f"{path}: {len(parts)} partitions, the table holds 1 to {MAX_ENTRIES}")
	if parts[0][2] != 0:
		fail(path, parts[0][0], "the first partition must start at 0 (the SPL lives there)")
	if not any(p[1] == "kernel" for p in parts):
		sys.exit(f"{path}: no 'kernel' partition: the SPL would have nothing to boot")
	end = 0
	for n, name, off, size, _, _ in parts:
		if off < end:
			fail(path, n, f"'{name}' at {off:#x} overlaps the partition before it (ends at {end:#x})")
		end = off + size
	if end > 1 << 32:
		sys.exit(f"{path}: the partitions go past 4 GiB")


def main():
	if len(sys.argv) != 3:
		sys.exit(__doc__)
	src, dst = sys.argv[1:]
	parts = parse(src)
	check(src, parts)
	table = b"nand" + struct.pack("<I", len(parts))
	for _, name, off, size, mask, mgr in parts:
		table += name.encode().ljust(32, b"\0") + struct.pack("<4I", size, off, mask, mgr)
	table = table.ljust(TABLE_SIZE, b"\xff")
	with open(dst, "wb") as f:
		f.write(table)


if __name__ == "__main__":
	main()
