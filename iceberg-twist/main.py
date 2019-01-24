import serial
import struct
from time import sleep
from os import remove

# sensor = serial.Serial('/dev/ttyUSB0', 57600, timeout=1)
# array = []
# with sensor as src:
#     for i in range(10):
#         bytes = src.read(2)
#         array.append(bytes)
#         print(bytes)
#         # print(bytes.decode('ascii'))

# sensor.open()
# sleep(5)
# bytes_number = sensor.in_waiting
# bytes = sensor.read(bytes_number)
# sensor.close()

# byte = bytes[0]


DEFAULT = {
    'path': '/dev/ttyUSB1',
    'baud': 115200,
    'timeout': 1}

FAST = {
    'path': '/dev/ttyUSB1',
    'baud': 115200,
    'timeout': 1}

def get_bytes(n: int, config: dict = DEFAULT) -> list:
    with serial.Serial(config['path'], config['baud'], timeout=config['timeout']) as sensor:
        sleep(n)
        bytes_waiting = sensor.in_waiting
        bytes = sensor.read(bytes_waiting)

    return bytes


def get_bytes_from_file(path: str) -> list:
    with open(path, 'rb') as source:
        bytes = source.read()

    return bytes


def bytes_to_file(path:str, byte_array: bytes) -> None:
    try:
        remove(path)
    except:
        pass
    
    with open(path, 'wb') as sink:
        sink.write(byte_array)


def get_timestamp(byte_array: bytes) -> int:
    (timestamp, ) = struct.unpack_from('i', byte_array, 6)
    return timestamp


def get_timestamp_byte(byte_array: bytes) -> bytes:
    byte = byte_array[6:7]

    return byte


def get_data_array(byte_array: bytes) -> bytes:
    data_array = byte_array[10:24]

    return data_array


def get_data(byte_array: bytes) -> list:
    data_iter = struct.iter_unpack('h', byte_array)
    data_array = [datum[0] for datum in data_iter]

    return data_array


if __name__ == '__main__':
    bytes = get_bytes(1, FAST)
    [byte for byte in bytes if byte == 58]
    byte = bytes.split(b'\x3a')[1]
    struct.unpack('h', bytearray(bytes[0:0+2]))

    timestamp = get_timestamp(byte)

    [len(byte.hex())/(2*4) for byte in bytes.split(b'\x3a')]

    test = get_bytes(60, FAST)
    [byte for byte in test if byte == 58]

    PATH = '/home/jthetzel/src/iceberg-twist/data/cJun27_bin16DYN.txt'
    OUT_PATH='/home/jthetzel/src/iceberg-twist/data/imu_bytes.txt'
    test = get_bytes_from_file(PATH)
    [byte for byte in test if byte == 58]
    [len(byte.hex())/(2*4) for byte in test.split(b'\x3a')]

    bytes_to_file(OUT_PATH, bytes)
