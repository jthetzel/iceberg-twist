-- print("hello");
-- random_bytes = io.open('/dev/urandom', 'r');
-- random_byte = random_bytes:read();
-- print(random_byte);

-- bytes = io.open('/dev/ttyUSB0', 'r');
-- byte = bytes:read();
-- print(byte);

local rs232 = require "rs232"
local out = io.stderr

local p, e = rs232.port('/dev/ttyUSB1',{
                           baud         = '_115200';
                           data_bits    = '_8';
                           parity       = 'NONE';
                           stop_bits    = '_1';
                           flow_control = 'OFF';
                           rts          = 'ON';
})

-- if e ~= rs232.RS232_ERR_NOERROR then
--    -- handle error
--    out:write(string.format("can't open serial port '%s', error: '%s'\n",
--                            port_name, rs232.error_tostring(e)))
--    return
-- end

p:open()
-- print(p:write('AT\r\n'))
-- print(p:read(640, 5000))
local data_read, size = p:read(64, 5000)
-- local e, d, l = p:read(64, 5000)
-- print(d)
-- print(l)
print(size)
print(data_read)
print(type(size))
print(type(data_read))

-- print(data_read[0])
-- print(data_read[1])
p:close()
-- print(rs232.RS232_ERR_NOERROR)
-- p.open()
-- local read_len = 1 -- read one byte
-- local timeout = 100 -- in miliseconds
-- local err, data_read, size = p:read(read_len, timeout)
-- p.close()
