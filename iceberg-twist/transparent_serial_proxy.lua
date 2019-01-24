-- Service: TransparentSerial
--

module(..., package.seeall)

--
-- Version information (required)
--
_VERSION = "0.1.0"

--
-- Module Globals
--

-- Handle to use for sending/receiving messages
local msgHdl = nil

local serialReaderHandle = nil
RS232Handle = nil


local function SendMsg(msg)
   trace(_NAME .. ": SendMsg()")
   if serialReaderHandle then
      local data = msg.fields.data
      tracef(_NAME .. ": ToRS232 %d bytes: %s", data:len(), toHex(data))
      RS232Handle:write(msg.fields.data)
   end
end


local function TransparentSerialThread()
   trace(_NAME .. ": transparent serial thread started")
  
   RS232Handle:setFrameConfig({maxRxSize=properties.rxBufSize, maxTxSize=5, minFrameSize=1})

   local frameQ = sched.createEventQ(10, RS232Handle:source(), 'FRAME')
   while true do
      -- Request a 'FRAME' event
      assert(RS232Handle:eventOnFrame(0, properties.rxTimeout))
      
      -- Wait for the frame
      local _, event, res, frame = frameQ:wait(-1)
      if res then
         local len = frame:len()
         if len &gt; 0 then         
            tracef(_NAME .. ": FromRS232 %d bytes: %s", len, toHex(frame))
            msgHdl:send(1, {data=frame})
         else
            -- trace(_NAME .. ": *** TIMEOUT ***")
         end
      else
         trace(_NAME .. ": transparent serial thread: Frame error: ", frame)
      end
   end
   trace(_NAME .. ": transparent serial thread stopped")
end


--
--  restart the serial reader.
--
local function transparentSerialRestart()
   trace(_NAME .. ": transparentSerialRestart()")
   if serialReaderHandle then
      -- Destroy the reader thread.
      serialReaderHandle:destroy()
      serialReaderHandle = nil

      -- Flush the UART
      RS232Handle:flush("*b")
      
      -- re-spawn the thread.
      serialReaderHandle = sched.spawn("Transparent Serial", TransparentSerialThread)
      serialReaderHandle:addTerminationHandler(transparentSerialStop)
   end
end

--
-- Stop transparent serial mode.
--
local function transparentSerialStop()  
   trace(_NAME .. ": transparentSerialStop()")
   if serialReaderHandle then
      -- Destroy the reader thread.
      serialReaderHandle:destroy()
      serialReaderHandle = nil

      -- Flush the UART
      RS232Handle:flush("*b")
  
      -- Disconnect from the RS232 port
      assert(svc.rs232.disconnect(RS232Handle))
      RS232Handle = nil
  
      -- Re-attach the shell.  If it is not enabled, it will not start.
      svc.shell.attach()
   end
end

--
-- Start transparent serial mode.
--
local function transparentSerialStart()
   if not serialReaderHandle then
      trace(_NAME .. ": transparentSerialStart()")

      -- Detach the shell from the serial port.
      svc.shell.detach()

      -- Connect to the RS232 port
      local errMsg
      RS232Handle, errMsg = svc.rs232.connect()
      if RS232Handle then
         serialReaderHandle = sched.spawn("Transparent Serial", TransparentSerialThread)
         serialReaderHandle:addTerminationHandler(transparentSerialStop)
      else
         trace(_NAME .. ": *** error: Unable to connect to RS232")      
         svc.shell.attach()
      end    
   end
end

--
-- Transparent serial command "tser"
--
local function TSerCmd(args)
   if #args &gt; 0 then
      if args[1] == "?" then
         print("Usage: tser start|stop")
      elseif args[1] == "start" then
         transparentSerialStart()
      elseif args[1] == "stop" then
         transparentSerialStop()
      else
         error("Invalid argument", 0)
      end
   else
      error("Missing 'stop|start' argument", 0)
  end
end


--
-- Configuration change
--
function onConfigChange(list)
   trace(_NAME .. ": onConfigChange")

   local enable = nil
   local restart = false

   -- check the list a change to the enable state.
   -- any other parameter requires a re-start
   for i = 1, #list do
      if list[i].name == "enabled" then
         enable = list[i].val
      else
         restart = true
      end
   end

   -- if enabling or disabling, no need to restart.   
   if type(enable) == "boolean" then
      if enable then
         print("Auto-starting transparent serial mode")
         transparentSerialStart()
      else
         transparentSerialStop()
      end
   elseif properties.enabled and restart then
      -- other properties changed and we are running, so re-start.
      transparentSerialRestart()
   end
end


--
-- Service termination
--
function onTermination()
   trace(_NAME .. ": onTermination()")
   transparentSerialStop()
end



--
-- table of forward message handling functions, indexed by MIN
--
local messageTable = {SendMsg}

--
-- Run service (required)
--
function entry()
   printf("%s: service started\n", _NAME)

   -- Simulate config change to enable/disable the shell.
   onConfigChange({{pin=1, name="enabled", val=properties.enabled}})
  
   local msgQ = sched.createEventQ(5, msgHdl, 'RX_DECODED')
   local breakQ = sched.createEventQ(2, '_UART_MAIN', 'BREAK')
   while true do
      local q, event, msg = sched.waitQ(-1, msgQ, breakQ)
      if q == msgQ then
         if msg.sin == _SIN and messageTable[msg.min] then
            messageTable[msg.min](msg)
         else
            msgHdl:msgError(msg.min, string.format("%s: invalid MIN (%d)", _NAME, msg.min))
         end
      elseif q == breakQ then
         if serialReaderHandle then
            transparentSerialStop()
         end
      else
         trace(_NAME .. ": Unexpected event Q= ", q)
      end
  end
end

--
-- Initialize service (required)
--
function init()
   -- Register with the message service
   msgHdl = svc.message.register(_SIN)
   if not msgHdl then
      svc.log.addDbgLog(svc.log.CRITICAL,
                        string.format("%s SIN already registered", _NAME))
   end
    
   -- Register the shell command.
   svc.shell.register("tser", TSerCmd, "Transparent serial service")      
end
