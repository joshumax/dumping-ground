#!/bin/bash
# This file does horrible things to patch an embedded zImage ramdisk in a uImage.

# Globals
SOURCE_UIMAGE=
DEST_UIMAGE=bonanza.combo
RDS_START=
RDS_LENGTH=
UNPACK_DIR="_ramdisk"
BSP_COMMENT="Linux-BSP10.14-CC2.9.9.99"
KERNEL_TMP=$(mktemp /tmp/kernelimage-XXX)

usage()
{
	echo "Usage: $0 -k <uImage> [-o <bonanza.combo>]" 1>&2; exit 1;
}

fatal()
{
	echo "$1"
	exit 1
}

rqd()
{
	"$@" || fatal "$* failed."
}

get_file_size()
{
        rqd stat -c %s "$1"
}

hexpatch()
{
	echo "Patching '$1' to '$2'"

	rqd xxd -plain "${KERNEL_TMP}" | tr -d '\n' > "${KERNEL_TMP}-hex"
	rqd sed -i "s/$1/$2/" "${KERNEL_TMP}-hex"
	rqd xxd -plain -revert "${KERNEL_TMP}-hex" "${KERNEL_TMP}"
	rqd rm "${KERNEL_TMP}-hex"
}

pad_to()
{
	echo "Padding ramdisk..."

	psize="$(get_file_size "$1")"
	rqd dd if=/dev/zero of="${KERNEL_TMP}-zeroes" count=1 bs=$(($2 - $psize))
	rqd cat "${KERNEL_TMP}-zeroes" >> "$1"
	rqd rm "${KERNEL_TMP}-zeroes"
}

extract_zimage_from_uimage()
{
	echo "Extracting kernel from uImage..."

	file "${SOURCE_UIMAGE}" | grep "u-boot" >/dev/null || fatal "Input not a uImage!"
	kernel_len=$(rqd file "${SOURCE_UIMAGE}" | grep -oP "([0-9]*)(?= bytes)")

	echo "Kernel image length: ${kernel_len}"

	# Strip off uImage header and truncate extra data
	rqd tail -c+65 < "${SOURCE_UIMAGE}" > "${KERNEL_TMP}"
	rqd dd if="${KERNEL_TMP}" of="${KERNEL_TMP}-stripped" bs="${kernel_len}" count=1
	rqd mv "${KERNEL_TMP}-stripped" "${KERNEL_TMP}"
}

try_decompress()
{
	# The obscure use of the "tr" filter is to work around older versions of
	# "grep" that report the byte offset of the line instead of the pattern.

	# Try to find the header ($1) and decompress from here

	echo "Deflating zImage..."

	found=false
	for	pos in `tr "$1\n$2" "\n$2=" < "${KERNEL_TMP}" | grep -abo "^$2"`
	do
		pos=${pos%%:*}
		rqd tail -c+$pos "${KERNEL_TMP}" | $3 > "${KERNEL_TMP}-deflated" 2> /dev/null
		if [ ! -z "$(grep "Linux version" "${KERNEL_TMP}-deflated")" ]; then
			echo "Kernel successfully decompressed"

			found=true
			break
		fi
	done

	if [ found = false ]; then
		fatal "Could not decompress zImage!"
	fi

	rqd mv "${KERNEL_TMP}-deflated" "${KERNEL_TMP}"
}

find_ramdisk_offsets()
{
	echo "Searching for __irf_start and __irf_end..."

	rqd vmlinux-to-elf "${KERNEL_TMP}" "${KERNEL_TMP}-elf"
	RDS_START="$(rqd objdump -x "${KERNEL_TMP}-elf" | grep __irf_start | sed 's/\([0-9a-z]*\).*/0x\1/' | xargs printf "%d\n")"
	rds_end="$(rqd objdump -x "${KERNEL_TMP}-elf" | grep __irf_end | sed 's/\([0-9a-z]*\).*/0x\1/' | xargs printf "%d\n")"

	load_addr="$(rqd objdump -x "${KERNEL_TMP}-elf" | grep -m 1 vaddr | sed 's/.* vaddr \([0-9a-z]*\).*/\1/' | xargs printf "%d\n")"
	RDS_START="$(expr $RDS_START - $load_addr)"
	RDS_LENGTH="$(expr $rds_end - $load_addr - $RDS_START)"

	echo "Ramdisk found. Start: ${RDS_START}, Length: ${RDS_LENGTH}"
}

extract_ramdisk()
{
	echo "Extracting ramdisk from kernel image..."

	if [ -d "${UNPACK_DIR}" ]; then
		echo "Ramdisk directory already exists, skipping unpacking!"
		cd "${UNPACK_DIR}"
		return
	fi

	rqd mkdir "${UNPACK_DIR}" && cd "${UNPACK_DIR}"
	rqd dd if="${KERNEL_TMP}" of="${KERNEL_TMP}-rtmp1" bs="${RDS_START}" skip=1
	rqd dd if="${KERNEL_TMP}-rtmp1" of="${KERNEL_TMP}-rtmp2" bs="${RDS_LENGTH}" count=1
	rqd mv "${KERNEL_TMP}-rtmp2" "${KERNEL_TMP}-ramdisk"
	rqd rm "${KERNEL_TMP}-rtmp1"

	# We only support XZ-compressed ramdisks right now
	rdextract_unxz "${KERNEL_TMP}-ramdisk"
}

rdextract_unxz()
{
	rqd unxz -c "$1" | cpio -idmv
}

repack_ramdisk()
{
	echo "Re-packing ramdisk into kernel..."

	# We only support XZ-compressed ramdisks right now
	rdrepack_xz "${KERNEL_TMP}-ramdisk"

	if [ "$(get_file_size "${KERNEL_TMP}-ramdisk")" -gt "${RDS_LENGTH}" ]; then
		fatal "New ramdisk is too large to fit in existing kernel image! Maybe try 'xz -9?'"
	fi

	pad_to "${KERNEL_TMP}-ramdisk" "${RDS_LENGTH}"
	rqd dd if="${KERNEL_TMP}-ramdisk" of="${KERNEL_TMP}" obs="${RDS_START}" seek=1 conv=notrunc
}

rdrepack_xz()
{
	rqd find . 2>/dev/null | cpio -H newc -R root:root -o | xz --check=crc32 --lzma2=dict=1MiB > "$1"
}

build_uimage()
{
	echo "Building a new uImage..."

	rqd cd ..
	rqd mkimage -A arm -O linux -T kernel -C none -a 0x10008000 -e 0x10008000 -n "${BSP_COMMENT}" -d "${KERNEL_TMP}" "${DEST_UIMAGE}"
}

# Main stuff
trap "rm -f ${KERNEL_TMP}*" 0

while getopts ":k:o:" x; do
    case "${x}" in
        k)
            param_k=${OPTARG}
            ;;
        o)
            param_o=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

# Input uImage name
if [ -z "${param_k}" ]; then
    usage
fi
SOURCE_UIMAGE="${param_k}"

# Output uImage name
if [ ! -z "${param_o}" ]; then
	DEST_UIMAGE="${param_o}"
fi

extract_zimage_from_uimage
try_decompress '\037\213\010' xy gunzip
find_ramdisk_offsets
extract_ramdisk

# We can make our ramdisk modifications now
read -p "Ramdisk extracted to '${UNPACK_DIR}'. Make modifications now and press enter to re-pack!"

repack_ramdisk

# Fix broken touchscreen driver
hexpatch "0020a0e3dde6ffeb" "0120a0e3dde6ffeb"
hexpatch "0120a0e3043098e5" "0020a0e3043098e5"

build_uimage

echo "Image successfully generated as ${DEST_UIMAGE} - Have fun!"
