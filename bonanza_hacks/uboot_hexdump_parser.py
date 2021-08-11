import sys
import io
import os

BYTES_IN_LINE = 0x10

def print_usage():
    print("Usage:\n\t%s outfile start_addr length dump_1 [dump_2...]" % sys.argv[0])


def parse_dumps(outfile, start_addr, addr_length, dumps):
    current_addr = start_addr

    while current_addr < start_addr + addr_length:
        address_ok = False

        # Loop through hex dumps until a dump line is deemed correct
        for cur_file in range(0, len(dumps)):

            fp = dumps[cur_file]
            while True:
                last_pos = fp.tell()
                line = fp.readline()

                # Is there anything left to read?
                if line == '':
                    break

                # Strip off the newlines/whitespace
                line = line.strip()

                # Ignore empty stripped lines
                if not line:
                    continue

                # Parse the current line
                try:
                    data, ascii_data = line.split("    ", maxsplit = 1)
                    straddr, strdata = data.split(maxsplit = 1)
                    p_addr = int.from_bytes(bytes.fromhex(straddr[:-1]), byteorder = 'big')
                except:
                    print("NOTE: Unpacking error at addr %x in dump %d. Skipping line... Data: '%s'"
                    % (current_addr, cur_file, line))
                    continue

                # Fast-forward until we're at the correct current address
                if p_addr < current_addr:
                    continue

                # Are we missing the address we need?
                if p_addr > current_addr:
                    print("NOTE: Next match %x too high for addr %x in dump %d. Correcting."
                    % (p_addr, current_addr, cur_file))
                    # Seek back to before this line if still less than total dump size
                    if p_addr <= start_addr + addr_length:
                        fp.seek(last_pos)

                    break

                try:
                    data = bytes.fromhex(strdata)
                except:
                    print("NOTE: Hex decoding error at addr %x in dump %d. Correcting. Data: '%s'"
                    % (p_addr, cur_file, strdata))
                    break

                if len(data) != BYTES_IN_LINE:
                    print("NOTE: Unexpected number of bytes in line at addr %x in dump %d. Correcting."
                    % (p_addr, cur_file))
                    break

                hex_to_ch = {}
                for b, c in zip(data, ascii_data):
                    try:
                        if hex_to_ch[b] != c:
                            print("NOTE: Inconsistency between hex data and ASCII data at addr %x in dump %d. Correcting."
                            % (p_addr, cur_file))
                            break
                    except KeyError:
                        hex_to_ch[b] = c

                print("Address %x OK" % p_addr)
                address_ok = True

                # Append the bytes to the file
                outfile.write(data)
                break

            if address_ok:
                break

        # None of the dumps have valid data for this address block
        if not address_ok:
            sys.exit("ERROR: Could not find valid data in all dumps for address %x!" % current_addr)

        current_addr += BYTES_IN_LINE


if __name__ == "__main__":
    if len(sys.argv) < 5:
        print_usage()

    outfile = sys.argv[1]
    start_addr = int(sys.argv[2], 16)
    dump_length = int(sys.argv[3], 16)

    print("Start address: 0x%x, Length: 0x%x" % (start_addr, dump_length))

    files = []
    for i in range(4, len(sys.argv)):
        files.append(open(sys.argv[i], "r", encoding="ascii"))

    try:
        os.remove(outfile)
    except FileNotFoundError:
        pass

    outfile = open(outfile, 'ab+')

    parse_dumps(outfile, start_addr, dump_length, files)

    # Close files
    outfile.close()
    for file in files:
        file.close()
