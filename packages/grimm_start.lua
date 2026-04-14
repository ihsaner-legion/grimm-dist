-- @description grimm: start assistant
-- @author ihsan
-- @version 0.0.3
-- @about Starts the grimm mix assistant: launches the grimm app, attaches
--   grimm_master.jsfx to the master bus, and streams analysis data. Re-run
--   this action to stop and tear down.
-- @provides [main] .

-- ---------- toggle: if already running, perform stop sequence and exit ----------
local function stop_and_exit()
  reaper.ShowConsoleMsg("[grimm] stop requested — tearing down\n")

  -- Detach JSFX if we added it. Duplicates the logic in the main flow
  -- because the helpers aren't in scope yet at first-invocation guard time.
  if reaper.GetExtState("grimm", "attached_jsfx") == "1" then
    local master = reaper.GetMasterTrack(0)
    local n = reaper.TrackFX_GetCount(master)
    local i = 0
    while i < n do
      local _, name = reaper.TrackFX_GetFXName(master, i, "")
      if name:find("grimm_master", 1, true) then
        reaper.TrackFX_Delete(master, i)
        reaper.ShowConsoleMsg("[grimm] detached grimm_master from master\n")
        break
      end
      i = i + 1
    end
    reaper.DeleteExtState("grimm", "attached_jsfx", false)
  end

  reaper.DeleteExtState("grimm", "bridge_running", false)
  -- The previous instance's defer loop observes bridge_running == "" and
  -- exits on its next tick (see `reap` below).
end

if reaper.GetExtState("grimm", "bridge_running") == "1" then
  stop_and_exit()
  return
end
reaper.SetExtState("grimm", "bridge_running", "1", false)

-- ---------- logging helpers ----------
local function log(msg)
  reaper.ShowConsoleMsg("[grimm] " .. msg .. "\n")
end

log("starting grimm v0.0.3")

-- ---------- launch the Tauri app ----------
-- We use `open -a grimm` so macOS LaunchServices resolves the app path
-- regardless of /Applications vs ~/Applications. If the app isn't
-- installed, `open` exits non-zero and we bail cleanly.
local function launch_app()
  local proc = io.popen("open -a grimm 2>&1; echo __rc=$?", "r")
  if not proc then return false, "io.popen failed" end
  local output = proc:read("*a") or ""
  proc:close()
  -- `open` writes errors to stderr; we capture both streams and check rc.
  local rc = output:match("__rc=(%d+)") or "1"
  if rc ~= "0" then
    return false, output
  end
  return true
end

local ok, err = launch_app()
if not ok then
  log("app not found — install grimm.app from the latest .dmg")
  log("  (open error: " .. tostring(err):gsub("\n", " ") .. ")")
  reaper.DeleteExtState("grimm", "bridge_running", false)
  return
end
log("launched grimm.app")

-- ---------- gmem ----------
reaper.gmem_attach("grimm")
log("attached to gmem namespace 'grimm'")

-- ---------- JSFX attach/detach on master ----------
local JSFX_NAME = "grimm_master"

local function find_master_grimm_fx()
  local master = reaper.GetMasterTrack(0)
  local n = reaper.TrackFX_GetCount(master)
  local i = 0
  while i < n do
    local _, name = reaper.TrackFX_GetFXName(master, i, "")
    if name:find(JSFX_NAME, 1, true) then
      return master, i
    end
    i = i + 1
  end
  return master, -1
end

local function attach_jsfx()
  local master, idx = find_master_grimm_fx()
  if idx >= 0 then
    log("JSFX already on master (slot " .. idx .. "), leaving in place")
    reaper.SetExtState("grimm", "attached_jsfx", "0", false)
    return true
  end
  local new_idx = reaper.TrackFX_AddByName(master, JSFX_NAME, false, -1)
  if new_idx < 0 then
    return false
  end
  log("attached " .. JSFX_NAME .. " to master (slot " .. new_idx .. ")")
  reaper.SetExtState("grimm", "attached_jsfx", "1", false)
  return true
end

local function detach_jsfx_if_ours()
  if reaper.GetExtState("grimm", "attached_jsfx") ~= "1" then
    return
  end
  local master, idx = find_master_grimm_fx()
  if idx >= 0 then
    reaper.TrackFX_Delete(master, idx)
    log("detached " .. JSFX_NAME .. " from master")
  end
  reaper.DeleteExtState("grimm", "attached_jsfx", false)
end

if not attach_jsfx() then
  log("grimm_master.jsfx not found — reinstall grimm via ReaPack")
  reaper.DeleteExtState("grimm", "bridge_running", false)
  return
end

-- ---------- socket state (io.popen + nc) ----------
local SOCK_PATH = "/tmp/grimm.sock"

local pipe = nil
local connected = false
local last_retry = 0
local RETRY_INTERVAL = 1.0

local last_warn_log = 0
local WARN_LOG_INTERVAL = 1.0

local function try_connect()
  local p, err = io.popen("nc -U " .. SOCK_PATH, "w")
  if not p then return nil, err end
  return p
end

local function disconnect(reason)
  if pipe then pcall(function() pipe:close() end) end
  pipe = nil
  if connected then
    connected = false
    log("disconnected: " .. tostring(reason or ""))
  end
end

reaper.atexit(function()
  disconnect("script exit")
  detach_jsfx_if_ours()
  reaper.DeleteExtState("grimm", "bridge_running", false)
end)

-- reap(): the defer tick. Runs at ~30 Hz on Reaper's main thread.
local function reap()
  -- Cooperative cancellation: a second invocation of this script clears
  -- bridge_running, and we see that here and exit the defer chain.
  if reaper.GetExtState("grimm", "bridge_running") ~= "1" then
    disconnect("stopped by second invocation")
    detach_jsfx_if_ours()
    return
  end

  local now = reaper.time_precise()

  -- reconnect if needed
  if not pipe and (now - last_retry) >= RETRY_INTERVAL then
    last_retry = now
    local p, err = try_connect()
    if p then
      pipe = p
      if not connected then
        connected = true
        log("connected to " .. SOCK_PATH)
      end
    else
      if not connected and (now - last_warn_log) >= WARN_LOG_INTERVAL then
        last_warn_log = now
        log("not connected, retrying (" .. tostring(err) .. ")")
      end
    end
  end

  local seq       = reaper.gmem_read(0)
  local rms       = reaper.gmem_read(1)
  local n         = reaper.gmem_read(2)
  local sr        = reaper.gmem_read(3)
  local band_sub  = reaper.gmem_read(4)
  local band_lm   = reaper.gmem_read(5)
  local band_mid  = reaper.gmem_read(6)
  local band_hm   = reaper.gmem_read(7)
  local band_hi   = reaper.gmem_read(8)
  local peak_l    = reaper.gmem_read(9)
  local peak_r    = reaper.gmem_read(10)
  local phase_c   = reaper.gmem_read(11)

  -- Compensate for master fader: JSFX sees pre-fader signal,
  -- so scale peaks by the fader gain to reflect post-fader reality.
  local master = reaper.GetMasterTrack(0)
  local fader_vol = reaper.GetMediaTrackInfo_Value(master, "D_VOL")
  peak_l = peak_l * fader_vol
  peak_r = peak_r * fader_vol

  if pipe and n > 0 then
    local line = string.format(
      '{"v":2,"seq":%d,"rms":%.6f,"n":%d,"sr":%d,'
      .. '"bands":{"sub":%.6f,"low_mid":%.6f,"mid":%.6f,"high_mid":%.6f,"high":%.6f},'
      .. '"peak_l":%.6f,"peak_r":%.6f,"phase_corr":%.6f}\n',
      seq, rms, n, sr,
      band_sub, band_lm, band_mid, band_hm, band_hi,
      peak_l, peak_r, phase_c
    )
    local ok, err = pipe:write(line)
    if ok then
      pipe:flush()
    else
      disconnect(err)
    end
  end

  reaper.defer(reap)
end

reap()
