import sys
import struct

def extract_crc(ko_path, symbol_name):
    with open(ko_path, 'rb') as f:
        data = f.read()
    
    target = f"__crc_{symbol_name}".encode()
    pos = data.find(target)
    if pos == -1:
        print(f"Symbol {symbol_name} not found")
        return
    
    # In many MTK modules, the CRC is stored as a 4-byte value 
    # For now, let's just find the string and look around for hex values
    print(f"Found {target.decode()} at offset {hex(pos)}")
    
    # Let's dump the surrounding 64 bytes
    start = max(0, pos - 32)
    end = min(len(data), pos + 32)
    chunk = data[start:end]
    print(f"Hex dump around {symbol_name}:")
    print(chunk.hex())

if __name__ == "__main__":
    extract_crc(sys.argv[1], sys.argv[2])
