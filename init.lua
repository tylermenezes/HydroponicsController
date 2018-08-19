-------------------
-- Configuration --
-------------------

tz = -7*60*60
timeSynchronizeInterval = 1*60*60
configSynchronizeInterval = 5*60
ssid = ""
pass = ""
configUrl = "http://tyler.vc/plant-control.json"
device = "closet"


----------------------
-- Helper Functions --
----------------------

-- Config display
function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

function startOfDay(timestamp)
    cal = rtctime.epoch2cal(timestamp)
    return timestamp - ( (cal["hour"]*3600) + (cal["min"]*60) + cal["sec"] )
end

function getTimeStringParts(time)
    timeGetPart = string.gmatch(time, "%w+")

    -- Calculate start time
    mL = tonumber(timeGetPart())
    timeH = tonumber(timeGetPart())
    timeM = tonumber(timeGetPart())
    timeS = tonumber(timeGetPart())
    timeDiv = timeGetPart()
    timeDiv = timeDiv and tonumber(timeDiv) or nil

    return { hour = timeH, min = timeM, sec = timeS, div = timeDiv, mL = mL }
end

-- Error display
errors = { time = true, config = true }
setError = function(source, isOn)
    errors[source] = isOn

    hasAnyError = false
    for _, err in pairs(errors) do
        if err then hasAnyError = true end
    end

    gpio.write(4, hasAnyError and gpio.LOW or gpio.HIGH)
end

-- Pump/Pin Conversion
pumpToPin = function(pump)
    if (pump <= 1) then return pump + 3 end
    if (pump <= 4) then return 4-pump end
    if (pump <= 6) then return (6-pump) + 5 end
    if (pump <= 8) then return pump end
end

-- Update the time from a network share
timeSynchronized = false
timeSynchronize = function()
    if (wifi.sta.getip() == nil) then
        print("no wifi")
        tmr.create():alarm(1000, tmr.ALARM_SINGLE, timeSynchronize) -- Re-sync immediately
        return
    end

    sntp.sync("132.163.96.3", function(sec, usec, server, info)
        setError("time", false)
        timeSynchronized = true
        print('synchronized time from the server')
        rtctime.set(sec+tz, usec)
    end,
    function()
        setError("time", true)
        print('could not get time from the server')
        tmr.create():alarm(1000, tmr.ALARM_SINGLE, timeSynchronize) -- Re-sync immediately
    end)
end

-- Configuration update
config = {}
mLPerMin = 0
configSynchronized = false
configSynchronize = function()
    if (wifi.sta.getip() == nil) then
        tmr.create():alarm(1000, tmr.ALARM_SINGLE, configSynchronize)
        return
    end

    http.get(configUrl.."?c="..node.random(0,99999), nil, function(statusCode, body)

        -- Did the config exist?
        if (statusCode == 200) then
            tmpConfig = sjson.decode(body)

            -- Does it contain config for this device?
            if (tmpConfig[device] ~= nil) then
                configSynchronized = true
                setError("config", false)

                config = tmpConfig[device]["plants"]
                mLPerMin = tmpConfig[device]["mLPerMin"]

                print('config synchronized:')
                print(dump(config))
            else
                print('could not synchronize config from server: config for '..device..' not found')
                setError("config", true)
                tmr.create():alarm(1000, tmr.ALARM_SINGLE, configSynchronize)
            end

        else
            print('could not synchronize config from '..configUrl..': error code '..statusCode)
            setError("config", true)
            tmr.create():alarm(1000, tmr.ALARM_SINGLE, configSynchronize)
        end
    end)
end



-----------
-- Setup --
-----------

-- Set pin defaults for each pump
for pin=0,8 do
    gpio.mode(pumpToPin(pin), gpio.OUTPUT)
    gpio.write(pumpToPin(pin), gpio.LOW)
end
setError("time", true)
setError("config", true)

-- Connect to Wifi
wifi.setmode(wifi.STATION)
station_cfg={}
station_cfg.ssid=ssid
station_cfg.pwd=pass
station_cfg.save=true
wifi.sta.config(station_cfg)
wifi.sta.connect()
net.dns.setdnsserver('208.67.222.222', 0)
net.dns.setdnsserver('208.67.220.220', 1)

-- Keep the time in-sync
timeSynchronize()
tmr.create():alarm(timeSynchronizeInterval*1000, tmr.ALARM_AUTO, timeSynchronize)

-- Keep the configuration in-sync
configSynchronize()
tmr.create():alarm(configSynchronizeInterval*1000, tmr.ALARM_AUTO, configSynchronize)



--------------------------
-- Plant Watering Logic --
--------------------------
wateringTick = function()

    -- Ensure we have everything we need to make a watering decision
    if not (timeSynchronized and configSynchronized) then
        print(".")
        return
    end

    now = rtctime.get()
    nowD = rtctime.epoch2cal(now)["yday"]
    nowS = startOfDay(now)

    -- Check whether each plant should be on or off
    for _, plantConfig in ipairs(config) do

        isWatering = false
        for _, time in ipairs(plantConfig["schedule"]) do
            timeConfig = getTimeStringParts(time)
            starts = nowS + ( (timeConfig["hour"]*3600) + (timeConfig["min"]*60) + timeConfig["sec"] )
            ends = starts + math.floor(timeConfig["mL"]/mLPerMin*60)

            if (now > starts and now < ends and (timeConfig["div"] == nil or (nowD%timeConfig["div"] == 0))) then
                isWatering = true
            end
        end

        gpio.write(pumpToPin(plantConfig["pump"]), isWatering and gpio.HIGH or gpio.LOW)
    end
end
tmr.create():alarm(1000, tmr.ALARM_AUTO, wateringTick)
