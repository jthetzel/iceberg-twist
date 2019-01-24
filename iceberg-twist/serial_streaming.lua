--
-- Company:             SkyWave Mobile Communications
-- Department:          Field Application Engineering
-- Contact:             www.skywave.com / support@skywave.com
--
-- Project:             Application Note 202 - Transparent Serial Streaming
--
-- Description:         This service supports transparently forwarding data (stream of bytes)
--                      between the local RS-232 serial port and a remote application.
--
-- Revision History:    v2.0.1 - Bug-fix Release (September 10, 2013).
--                             ~ Fixed issue where configuration changes might not have sent a status report.
--
--                      v2.0.0 - Feature Release (March 27, 2013).
--                             + Added To-Mobile (Tx) queue for delayed writing of To-Mobile data when DTE is disconnected (low power support).
--                             + Added To/From-Mobile data lifetime management.
--                             + Added functionality to the shell command.
--                             + Added support for enabling/disabling StatusReports based on EventType.
--
--                             ~ Renamed properties to use CamelCase. Some properties were also renamed for clarity.
--                             ~ Renamed messages and fields to use CamelCase. Some fields were also renamed for clarity.
--
--                             + Service code is now spread over multiple files to allow easier OTA update.
--                             + Introduces more advanced Lua concepts (metatables, environment, protective-calls).
--
--                      v1.1.2 - Firmware compatibility release (February 28, 2012).
--                             ~ Changed how TX_STATUS event is handled to be compatible with firmware 1.X and 2.X.
--
--                      v1.1.1 - Bug fix release (November 9, 2011).
--                             ~ Fixed issue with SerialStream command not working properly.
--                             ~ Fixed issue where changing certain properties would detach the Shell instantly.
--
--                      v1.1.0 - New feature release (November 1, 2011).
--                             + Added support for using "raw" From/To-Mobile messages.
--                             - Application is no longer forcing the RS-232 transceiver to ON.
--                             - Application no longer supports a startup delay.
--                             ~ Fixed issue where changing the enabled property would not change the service's status.
--
--                      v1.0.0 - Initial release (September 12, 2011).
--
module(..., package.seeall)

--
-- Version information (required)
-- (See version.lua and init().)
--
_VERSION = "N/A"

--[[ Environment shared between all modules (similar to http://www.lua.org/manual/5.1/manual.html#pdf-package.seeall). ]]
local Env = setmetatable({ }, {__index=_M})
--[[ The "Main" module's namespace (which is shared with other modules). ]]
local Main = { }

--[[ Internal Variables. ]]
local cfgQ -- Event queue used for collecting of configuration-related events.
local regQ -- Event queue used for collecting (un)registration events (see Main.RegisterQ() and Main.UnregisterQ()).
local tmrQ -- Event queue used for collecting timer events (see Main.SetStatus()).
local EventQs = { }  -- A table of (registered) event queues and associated event-handling functions.

local changedQ = false -- (see Main.RegisterQ() and Main.UnregisterQ()).
local pauseCount = 0 -- Count of how many times the service was paused.

--
-- Function:      Env.addDbgLog
--
-- Description:   Add a new entry to the debug log, if the specified level is enabled (see svc.log in [T202]).
--
-- Parameters:    lvl - the debug log level.
--                fmt - a message (string) which can optionally contain format specifiers.
--                ... - zero or more arguments matching the format specifiers in fmt.
--
function Env.addDbgLog(lvl, fmt, ...)
  -- protectively call the string.format() method, constructing the message to be logged.
  local res, msg = pcall(string.format, fmt, ...)
  -- add the resulting message (or the error from pcall) to the debug log.
  svc.log.addDbgLog(lvl, Env.Const.Name .. ": " .. msg)
end

--
-- Function:      Main.RegisterQ
--
-- Description:   Register a new event queue (and associated callback function).
--                Registered event queues are used by the entry() function to
--                process events on behalf of other modules.
--
-- Parameters:    srcQ - the event queue to register.
--                func - the function to be called when an event is collected by the queue.
--
function Main.RegisterQ(srcQ, func)
  if (EventQs[srcQ]) then
    EventQs[srcQ] = func -- change the event queue's associated function.
  else
    EventQs[srcQ] = func -- register the new event queue.
    if (not changedQ) then
      sched.post(EventQs, 'REGISTER_Q')
      changedQ = true
    end
  end
end

--
-- Function:      Main.UnregisterQ
--
-- Description:   Unregister a previously registered event queue.
--
-- Parameters:    srcQ - the event queue to unregister.
--
function Main.UnregisterQ(srcQ)
  if (EventQs[srcQ]) then
    EventQs[srcQ] = nil -- unregister the event queue.
    if (not changedQ) then
      sched.post(EventQs, 'UNREGISTER_Q')
      changedQ = true
    end
  end
end

--
-- Function:      Main.SetStatus
--
-- Description:   Change the service's status.
--
-- Parameters:    enabled - whether the service should be enabled.
--                timeout - amount of time in seconds after which the service will be in the new status (nil, 0 or less for now).
--
-- Returns:       boolean - true when successful, false otherwise.
--                string - nil when successful, an error message otherwise.
--
function Main.SetStatus(enabled, timeout)
  local res, err = true
  local oldStatus = Main.CurrentStatus

  if (enabled) and (Main.CurrentStatus ~= Env.Const.Status.Enabled) then -- service needs to be enabled.
    if (not timeout) or (timeout &lt;= 0) then -- enable service right away.
      res, err = Env.Serial.Open()
      if (res) then
        Env.addDbgLog(svc.log.INFO, "service is now enabled")
        Main.CurrentStatus, res, err = Env.Const.Status.Enabled, true
      else
        Env.addDbgLog(svc.log.INFO, "service is now disabled")
        Main.CurrentStatus = Env.Const.Status.Disabled
        Env.Serial.Close() -- attempt to properly close the serial port.
      end
      tmrQ:event():disarm() -- stop the delay timer.
    else -- delayed start.
      Env.addDbgLog(svc.log.INFO, "enabling service in %d second(s)", timeout)
      Main.CurrentStatus, res, err = Env.Const.Status.Paused, true
      tmrQ:event():arm(10 * timeout) -- start the delay timer.
    end
  elseif (not enabled) and (Main.CurrentStatus ~= Env.Const.Status.Disabled) then -- service needs to be disabled.
    if (Main.CurrentStatus == Env.Const.Status.Enabled) then -- serial port needs to be closed.
      res, err = Env.Serial.Close()
    else
      res, err = true
    end

    if (res) then
      if (not timeout) or (timeout &lt;= 0) then
        Env.addDbgLog(svc.log.INFO, "service is now disabled")
        Main.CurrentStatus, res, err = Env.Const.Status.Disabled, true
        tmrQ:event():disarm() -- stop the delay timer.
      else
        Env.addDbgLog(svc.log.INFO, "service is now paused for %d second(s)", timeout)
        Main.CurrentStatus, res, err = Env.Const.Status.Paused, true
        pauseCount = pauseCount + 1
        tmrQ:event():arm(10 * timeout) -- start the delay timer.
      end
    end
  end

  -- send status change notification (except on startup).
  if (oldStatus) and (Main.CurrentStatus ~= oldStatus) then
    Env.Msg.SendStatus(1 + Main.CurrentStatus)
  end
  return res, err
end

--
-- Function:      keys
--
-- Description:   Recursively extract all keys from an associative array, starting at a given element (key).
--
-- Parameters:    t - the table (associative array) to extract keys from.
--                k - the key from which the extraction should start (nil to start from the first).
--
-- Returns:       ... - the keys extracted from the table.
--
local function keys(t, k)
  -- next key in the table.
  local key = next(t, k)
  -- a nil key indicates the end of the table.
  if (key == nil) then return end
  -- return the extracted key, and the next.
  return key, keys(t, key)
end

--
-- Function:      shellCmd
--
-- Description:   Execute the shell command associated with the SerialStream service.
--
-- Parameters:    args - a table of command line arguments (empty if none).
--
local function shellCmd(args)
  -- extract first two command line arguments.
  local arg1, arg2 = table.remove(args, 1), table.remove(args, 1)

  if (arg1 == nil) then -- no argument? output status information.
    if (Main.CurrentStatus == Env.Const.Status.Paused) then
      local remaining = math.ceil((tmrQ:event():timeleft() / 10) + 0.5)
      printf("%s has been paused %d time(s) and is paused for another %d second(s).\n", Env.Const.Name, pauseCount, remaining)
    else
      printf("%s has been paused %d time(s) and is %s.\n", Env.Const.Name, pauseCount, Env.Const.StatusStr[Main.CurrentStatus]:lower())
    end
    printf("\n")

    printf("RS-232 &gt; OTA (Rx, %d queued)\n", #Env.RxQ)
    if (Env.RxQ.lastSent) then
      local now, uptime = os.time(), sys.uptime.framework('*s')
      local sentTime = (now or uptime) - (uptime - Env.RxQ.lastSent)
      printf("  Data Sent: %.2f kB / %d msg(s), Last on %s\n", Env.RxQ.byteSent / 1024, Env.RxQ.msgSent, os.date('%c', sentTime))
    else
      printf("  Data Sent: None\n")
    end
    if (Env.RxQ.lastLost) then
      local now, uptime = os.time(), sys.uptime.framework('*s')
      local lostTime = (now or uptime) - (uptime - Env.RxQ.lastLost)
      printf("  Data Lost: %.2f kB / %d msg(s), Last on %s\n", Env.RxQ.byteLost / 1024, Env.RxQ.msgLost, os.date('%c', lostTime))
    else
      printf("  Data Lost: None\n")
    end
    printf("\n")

    printf("OTA &gt; RS-232 (Tx, %d queued)\n", #Env.TxQ)
    if (Env.TxQ.lastSent) then
      local now, uptime = os.time(), sys.uptime.framework('*s')
      local sentTime = (now or uptime) - (uptime - Env.TxQ.lastSent)
      printf("  Data Sent: %.2f kB / %d msg(s), Last on %s\n", Env.TxQ.byteSent / 1024, Env.TxQ.msgSent, os.date('%c', sentTime))
    else
      printf("  Data Sent: None\n")
    end
    if (Env.TxQ.lastLost) then
      local now, uptime = os.time(), sys.uptime.framework('*s')
      local lostTime = (now or uptime) - (uptime - Env.TxQ.lastLost)
      printf("  Data Lost: %.2f kB / %d msg(s), Last on %s\n", Env.TxQ.byteLost / 1024, Env.TxQ.msgLost, os.date('%c', lostTime))
    else
      printf("  Data Lost: None\n")
    end
    printf("\n")

    return
  elseif string.match('enable', '^' .. arg1) then -- arg1 is e, en, ena, enab, enabl or enable?
    Main.SetStatus(true, tonumber(arg2))
    return
  elseif string.match('disable', '^' .. arg1) then -- arg1 is d, di, dis, disa, disab, disabl or disable?
    Main.SetStatus(false, tonumber(arg2))
    return
  end

  printf("Usage: %s [enable|disable [&lt;timeout&gt;]]\n", Env.Const.Name)
end

--
-- Function:      entry (required)
--
-- Description:   Main entry point for the service, called by the LSF once all services have been initialized.
--                Should this function ever throw an error or return somehow, the LSF will automatically restart it.
-- 
function entry()
  if (_VERSION == 'N/A') then
    printf("%s: service is not running (initialization failed)\n", _NAME)
    tracef("%s: service is not running (initialization failed)",   _NAME)
    onConfigChange = nil -- configuration changes should not be processed.
    sched.delay(-1) -- wait forever if the service did not initialize properly.
  end

  -- clear Rx and Tx queues.
  Env.RxQ:clear(true, true)
  Env.TxQ:clear(true, true)
  Main.SetStatus(properties.Enabled) -- open the serial port (if enabled).

  while (true) do
    local args = { sched.waitQ(-1, cfgQ, tmrQ, regQ, keys(EventQs)) } -- collect all return values from sched.waitQ() into a single table.
    local srcQ, evt = table.remove(args, 1), table.remove(args, 1) -- extract srcQ and evt from the collected return values.

    --[[ TODO: Enable for debugging purposes.
    tracef("Src=%s, Evt=%s, #Args=%d)", tostring(srcQ), tostring(evt), #args)
    --]]

    if (type(EventQs[srcQ]) == 'function') then
      local res, err = EventQs[srcQ](evt, unpack(args))
      if (not res) then
        Env.addDbgLog(svc.log.ERROR, "error processing event %s (source = %s, err = %s)", tostring(evt), tostring(srcQ), err)
        Main.SetStatus(false, 5) -- pause service for five (5) seconds on error.
      end
    elseif (srcQ == tmrQ) then
      Main.SetStatus(properties.Enabled) -- update the service's status when the timer expires.
    elseif (srcQ == regQ) then
      changedQ = false
    elseif (srcQ == cfgQ) then -- configuration-related events.
      if (evt == 'STATUS') then
        Main.SetStatus(properties.Enabled)
      elseif (evt == 'QUEUE_SIZE') then
        local isRxQueueSize, isTxQueueSize = unpack(args)
        if (isRxQueueSize) and (not Env.RxQ:setSize(properties.RxQueueSize)) then
          Env.Msg.SendStatus(Env.Const.EventType.RxDataLost)
        end
        if (isTxQueueSize) and (not Env.TxQ:setSize(properties.TxQueueSize)) then
          Env.Msg.SendStatus(Env.Const.EventType.TxDataLost)
        end
      elseif (evt == 'SERIAL_CONFIG') then
        if (not Env.Serial.SetConfig()) then -- re-configure the serial port.
          Main.SetStatus(false, 5) -- pause service for five (5) seconds on error.
        end
      end
    else
      Env.addDbgLog(svc.log.WARNING, "unhandled event %s (source = %s)", evt, srcQ)
    end
    collectgarbage('collect') -- force garbage collection.
  end
end

--
-- Function:      init (required)
--
-- Description:   Called by the LSF shortly after the service has been loaded,
--                so that the service can initialize its resources properly.
--
function init()
  Env.Main = Main
  -- configuration-related event queue.
  cfgQ = sched.createEventQ(5, {})
  cfgQ:name(string.format('Main: cfgQ_%d', _SIN))
  -- eventQ (de)registration event queue.
  regQ = sched.createEventQ(1, EventQs)
  regQ:name(string.format('Main: regQ_%d', _SIN))
  -- status timer event queue.
  tmrQ = sched.createEventQ(1, '_TIMER', sys.timer.create())
  tmrQ:name(string.format('Main: tmrQ_%d', _SIN))

  local res, err = sys.fs.chdir('/act/' .. _NAME:gsub('%.', '/')) -- set working directory.
  for _, name in ipairs({'Const','Queue','Msg','Serial','Version'}) do -- *always* load Const first and Version last.
    local path = sys.fs.expand(name:lower() .. '.lua')

    if (res) then res, err = loadfile(path) end -- load additional code file.
    if (res) then res, err = pcall(setfenv(res, Env)) end -- set shared environment and execute loaded code.
    if (res) and (type(err) == 'function') then res, err = pcall(err) end -- execute returned init function (if any).
    if (not res) then
      Env.addDbgLog(svc.log.ERROR, "could not load file '%s' (err = %s)", path, err)
      return
    end
    sys.kickWatchdog()
  end

  svc.shell.register(Env.Const.Name, shellCmd, "Manage the Serial Streaming Service") -- register shell command.
  _VERSION = Env.Const.Version or _VERSION -- update the version with the one in version.lua (when loaded properly).
end

--
-- Function:      onConfigChange (optional)
--
-- Description:   Called whenever some of the service's configuration properties are changed.
--
-- Parameters:    list - an array of changed properties.
--
function onConfigChange(list)
  local isStatus, isSerialConfig, isRxQueueSize, isTxQueueSize = false, false, false, false
  for _, prop in ipairs(list) do
    if (prop.name == 'Enabled') then -- change the service state.
      isStatus = true
    elseif (prop.name == 'RxQueueSize') then -- resize the Rx (From-Mobile) queue.
      isRxQueueSize = true
    elseif (prop.name == 'TxQueueSize') then -- resize the Tx (To-Mobile) queue.
      isTxQueueSize = true
    elseif (prop.name == 'ReadSize') or (prop.name == 'UseRawPayload') then -- serial-related configuration option(s) have changed.
      isSerialConfig = true
    end
  end
  if (isStatus) then sched.post(cfgQ:source(), 'STATUS') end -- status needs to be changed.
  if (isRxQueueSize) or (isTxQueueSize) then sched.post(cfgQ:source(), 'QUEUE_SIZE', isRxQueueSize, isTxQueueSize) end -- Rx/Tx queue(s) need to be changed.
  if (isSerialConfig) then sched.post(cfgQ:source(), 'SERIAL_CONFIG') end -- serial configuration needs to be changed.
end
