-- @description grimm: start assistant
-- @author ihsan
-- @version 0.0.6
-- @about Starts the grimm mix assistant: launches the grimm app, attaches
--   grimm_master.jsfx to the master bus, and streams analysis data. Re-run
--   this action to stop and tear down.
-- @provides [main] .

-- Matches Reaper's TrackFX_GetFXName output for our JSFX. Reaper derives the
-- display name from the `desc:` line ("grimm master", space) — not the filename
-- ("grimm_master", underscore). Accepting both forms keeps us robust to either
-- path, including projects with pre-v0.0.6 JSFX source embedded inline.
local function is_grimm_fx_name(name)
  return name:find("grimm master", 1, true) ~= nil
      or name:find("grimm_master", 1, true) ~= nil
end

-- ---------- toggle: if already running, perform stop sequence and exit ----------
local function stop_and_exit()
  reaper.ShowConsoleMsg("[grimm] stop requested — tearing down\n")

  -- Detach master JSFX if we auto-attached it. User-placed instances on other
  -- tracks are left in place. Duplicates the main-flow logic because helpers
  -- aren't in scope yet at first-invocation guard time.
  if reaper.GetExtState("grimm", "attached_jsfx") == "1" then
    local master = reaper.GetMasterTrack(0)
    local n = reaper.TrackFX_GetCount(master)
    local i = 0
    while i < n do
      local _, name = reaper.TrackFX_GetFXName(master, i, "")
      if is_grimm_fx_name(name) then
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

log("starting grimm v0.0.6")

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

-- ---------- JSFX name ----------
local JSFX_NAME = "grimm_master"

-- ---------- v0.0.6 session state ----------
-- instances: guid → { track = MediaTrack, fx_idx = int, slot = int }
-- Only contains currently-live (found this tick) tracks.
local instances = {}
-- guid → slot (session-scoped). Preserved through tombstone window so a
-- reappearing track revives its original slot.
local guid_to_slot = {}
-- slot → guid reverse map; kept in sync with guid_to_slot for O(N) reclaim sweeps.
local slot_to_guid = {}
-- Slots currently in use. For O(1) free-slot search.
local used_slots = {}
used_slots[0] = true  -- slot 0 reserved for master
-- Tombstone: { [slot] = timestamp when freed }. Slot not recycled until age >= 2 s.
local slot_tombstones = {}
local SLOT_TOMBSTONE_SECS = 2.0

-- Track-state diff cache. guid → last-emitted entry table.
local last_track_state = {}
-- Per-slot seq dedup: guid → last seq value emitted (spec §7.3 step 2).
-- Lua polls at ~30 Hz; JSFX FFT fires at ~23 Hz (48 kHz / 2048). Without
-- this gate the same window would be fed into the LUFS meter ~1.3× per window.
local last_seq = {}

-- Force a full track_state snapshot on the next tick that has a pipe.
-- Set to true on (re)connect so the app always gets state before audio.
local force_track_state_snapshot = false

-- ---------- JSFX master attach/detach ----------
local function find_master_grimm_fx()
  local master = reaper.GetMasterTrack(0)
  local n = reaper.TrackFX_GetCount(master)
  local i = 0
  while i < n do
    local _, name = reaper.TrackFX_GetFXName(master, i, "")
    if is_grimm_fx_name(name) then
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

-- Only detach from master if we auto-attached it. User-placed instances on other
-- tracks are intentionally left in place when the bridge stops.
local function detach_all_grimm_instances()
  if reaper.GetExtState("grimm", "attached_jsfx") == "1" then
    local master, idx = find_master_grimm_fx()
    if idx >= 0 then
      reaper.TrackFX_Delete(master, idx)
      log("detached " .. JSFX_NAME .. " from master")
    end
    reaper.DeleteExtState("grimm", "attached_jsfx", false)
  end
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
local last_cap_warn_log = 0
local WARN_LOG_INTERVAL = 1.0

local function try_connect()
  local p, e = io.popen("nc -U " .. SOCK_PATH, "w")
  if not p then return nil, e end
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
  detach_all_grimm_instances()
  reaper.DeleteExtState("grimm", "bridge_running", false)
end)

-- ---------- discovery helpers ----------

local function master_guid()
  return reaper.GetTrackGUID(reaper.GetMasterTrack(0))
end

local function next_free_slot()
  -- Slots 1..127 (0 reserved for master). First-fit.
  local i = 1
  while i <= 127 do
    if not used_slots[i] then return i end
    i = i + 1
  end
  return nil  -- cap hit; caller logs once.
end

local function reclaim_tombstones(now)
  for slot, t in pairs(slot_tombstones) do
    if (now - t) >= SLOT_TOMBSTONE_SECS then
      -- Expire the guid mapping so the slot becomes genuinely free.
      local guid = slot_to_guid[slot]
      if guid then
        guid_to_slot[guid] = nil
        slot_to_guid[slot] = nil
      end
      used_slots[slot] = nil
      slot_tombstones[slot] = nil
    end
  end
end

local function enumerate_grimm_instances()
  -- Returns guid → { track = MediaTrack, fx_idx = int } for every track
  -- (including master) that has a grimm_master JSFX loaded.
  local found = {}

  local function scan(track)
    local n = reaper.TrackFX_GetCount(track)
    for i = 0, n - 1 do
      local _, name = reaper.TrackFX_GetFXName(track, i, "")
      if is_grimm_fx_name(name) then
        local guid = reaper.GetTrackGUID(track)
        found[guid] = { track = track, fx_idx = i }
        break  -- one grimm per track max
      end
    end
  end

  scan(reaper.GetMasterTrack(0))
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    scan(reaper.GetTrack(0, i))
  end

  return found
end

local function assign_slots(found, now)
  -- Tombstone instances that disappeared this tick.
  -- guid_to_slot is intentionally kept so a reappearing track within the
  -- 2-second window revives its original slot (spec §7.1 step 4).
  -- instances is cleared because the MediaTrack/fx_idx refs are stale.
  for guid, _inst in pairs(instances) do
    if not found[guid] then
      local slot = guid_to_slot[guid]
      if slot and slot ~= 0 then
        slot_tombstones[slot] = now
        -- slot_to_guid stays set; reclaim_tombstones clears it on expiry.
      end
      instances[guid] = nil
      last_seq[guid] = nil  -- prevent unbounded growth on track churn
    end
  end

  -- Assign slots to each live instance.
  local mg = master_guid()
  for guid, inst in pairs(found) do
    local slot = guid_to_slot[guid]
    if not slot then
      if guid == mg then
        slot = 0
      else
        slot = next_free_slot()
        if not slot then
          if (now - last_cap_warn_log) >= WARN_LOG_INTERVAL then
            last_cap_warn_log = now
            log("slot cap (128) reached; track " .. guid .. " is not analysed")
          end
          goto continue
        end
      end
      guid_to_slot[guid] = slot
      slot_to_guid[slot] = guid
      used_slots[slot] = true
    end
    slot_tombstones[slot] = nil  -- cancel tombstone for both new and revived slots

    -- Write the slider if it doesn't already match.
    -- TrackFX_SetParamNormalized takes a [0,1] value; slider range is [0,127] step 1.
    local current_norm = reaper.TrackFX_GetParamNormalized(inst.track, inst.fx_idx, 0)
    local desired_norm = slot / 127
    if math.abs(current_norm - desired_norm) > (0.5 / 127) then
      reaper.TrackFX_SetParamNormalized(inst.track, inst.fx_idx, 0, desired_norm)
    end

    inst.slot = slot
    instances[guid] = inst
    ::continue::
  end
end

-- ---------- track-state helpers ----------

local function db_from_vol(vol)
  if vol <= 0 then return -120.0 end
  return 20.0 * math.log(vol, 10)
end

local function poll_track_state()
  -- Returns an array of snapshot entries for every track that has a grimm
  -- instance, with hierarchy fields derived via I_FOLDERDEPTH walk.

  local track_count = reaper.CountTracks(0)
  local master = reaper.GetMasterTrack(0)
  local stack = {}          -- stack of parent GUIDs for folder-depth tracking
  local tracks_by_guid = {}
  local track_order = {}

  -- Master: always first, depth 0, no parent.
  do
    local guid = reaper.GetTrackGUID(master)
    tracks_by_guid[guid] = {
      track = master, index = -1, depth = 0, parent_guid = nil, is_folder = false,
    }
    track_order[#track_order + 1] = guid
  end

  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(0, i)
    local guid = reaper.GetTrackGUID(tr)
    local depth = #stack
    local parent_guid = stack[#stack]
    local folder_change = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    local is_folder = folder_change >= 1
    tracks_by_guid[guid] = {
      track = tr, index = i, depth = depth, parent_guid = parent_guid, is_folder = is_folder,
    }
    track_order[#track_order + 1] = guid
    if folder_change >= 1 then
      stack[#stack + 1] = guid
    elseif folder_change < 0 then
      -- Multiple closes possible: folder_change = -1, -2, etc.
      for _ = 1, -folder_change do
        stack[#stack] = nil
      end
    end
  end

  -- Covered set: every track with a grimm instance, plus every folder
  -- ancestor up to the top. Ancestors are included so parent_track_id
  -- references always resolve within the snapshot (spec §5.2 example,
  -- §9.2 verification: "3-track folder session … reports parent_track_id,
  -- depth, is_folder for all entries").
  local covered = {}
  for guid, _ in pairs(instances) do
    local g = guid
    while g do
      covered[g] = true
      local info = tracks_by_guid[g]
      g = info and info.parent_guid or nil
    end
  end

  local out = {}
  for _, guid in ipairs(track_order) do
    if covered[guid] then
      local info = tracks_by_guid[guid]
      local tr = info.track
      local _, name = reaper.GetTrackName(tr)
      out[#out + 1] = {
        track_id        = guid,
        name            = name,
        index           = info.index,
        parent_track_id = info.parent_guid,
        depth           = info.depth,
        is_folder       = info.is_folder,
        solo            = reaper.GetMediaTrackInfo_Value(tr, "B_SOLO") > 0,
        mute            = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0,
        fader_db        = db_from_vol(reaper.GetMediaTrackInfo_Value(tr, "D_VOL")),
      }
    end
  end
  return out
end

local function snapshot_changed(new_state)
  if #new_state ~= 0 and next(last_track_state) == nil then
    return true  -- first snapshot
  end
  local seen = {}
  for _, t in ipairs(new_state) do
    seen[t.track_id] = true
    local prev = last_track_state[t.track_id]
    if not prev then return true end
    if prev.name            ~= t.name
    or prev.index           ~= t.index
    or prev.parent_track_id ~= t.parent_track_id
    or prev.depth           ~= t.depth
    or prev.is_folder       ~= t.is_folder
    or prev.solo            ~= t.solo
    or prev.mute            ~= t.mute
    or math.abs((prev.fader_db or 0) - (t.fader_db or 0)) > 0.01
    then
      return true
    end
  end
  -- Detect disappeared tracks.
  for guid, _ in pairs(last_track_state) do
    if not seen[guid] then return true end
  end
  return false
end

local function update_last_track_state(new_state)
  last_track_state = {}
  for _, t in ipairs(new_state) do
    last_track_state[t.track_id] = t
  end
end

-- ---------- JSON serialisation helpers ----------

local function escape_json_string(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return s
end

local function track_state_ndjson(snapshot)
  local entries = {}
  for _, t in ipairs(snapshot) do
    local parent = t.parent_track_id
      and ('"' .. escape_json_string(t.parent_track_id) .. '"')
      or "null"
    entries[#entries + 1] = string.format(
      '{"track_id":"%s","name":"%s","index":%d,"parent_track_id":%s,"depth":%d,'
      .. '"is_folder":%s,"solo":%s,"mute":%s,"fader_db":%.3f}',
      escape_json_string(t.track_id),
      escape_json_string(t.name),
      t.index,
      parent,
      t.depth,
      tostring(t.is_folder),
      tostring(t.solo),
      tostring(t.mute),
      t.fader_db
    )
  end
  return string.format('{"v":4,"kind":"track_state","tracks":[%s]}\n',
    table.concat(entries, ","))
end

-- ---------- defer tick ----------

-- reap(): runs at ~30 Hz on Reaper's main thread.
local function reap()
  -- Cooperative cancellation: a second invocation of this script clears
  -- bridge_running, and we observe that here and exit the defer chain.
  if reaper.GetExtState("grimm", "bridge_running") ~= "1" then
    disconnect("stopped by second invocation")
    detach_all_grimm_instances()
    return
  end

  local now = reaper.time_precise()

  -- Discovery + slot assignment (every tick, cheap main-thread calls).
  reclaim_tombstones(now)
  local found = enumerate_grimm_instances()
  assign_slots(found, now)

  -- reconnect if needed
  if not pipe and (now - last_retry) >= RETRY_INTERVAL then
    last_retry = now
    local p, e = try_connect()
    if p then
      pipe = p
      if not connected then
        connected = true
        log("connected to " .. SOCK_PATH)
        -- Guarantee track_state arrives before audio on every (re)connect.
        force_track_state_snapshot = true
      end
    else
      if not connected and (now - last_warn_log) >= WARN_LOG_INTERVAL then
        last_warn_log = now
        log("not connected, retrying (" .. tostring(e) .. ")")
      end
    end
  end

  -- Track-state polling + conditional emit.
  -- Gated behind `pipe` check: no point walking all tracks when disconnected.
  -- force_track_state_snapshot is set on (re)connect to guarantee the app
  -- receives a full snapshot before any audio messages.
  if pipe then
    local track_snapshot = poll_track_state()
    local should_send_state = force_track_state_snapshot or snapshot_changed(track_snapshot)
    if should_send_state then
      local line = track_state_ndjson(track_snapshot)
      local wr_ok, wr_err = pipe:write(line)
      if wr_ok then
        pipe:flush()
        update_last_track_state(track_snapshot)
        force_track_state_snapshot = false
      else
        disconnect(wr_err)
      end
    end
  end

  -- Per-slot v4 audio emission.
  if not pipe then
    reaper.defer(reap)
    return
  end

  for guid, inst in pairs(instances) do
    local base = inst.slot * 32
    local seq  = reaper.gmem_read(base + 0)
    local n    = reaper.gmem_read(base + 2)
    if n > 0 and seq ~= (last_seq[guid] or -1) then
      local rms      = reaper.gmem_read(base + 1)
      local sr       = reaper.gmem_read(base + 3)
      local band_sub = reaper.gmem_read(base + 4)
      local band_lm  = reaper.gmem_read(base + 5)
      local band_mid = reaper.gmem_read(base + 6)
      local band_hm  = reaper.gmem_read(base + 7)
      local band_hi  = reaper.gmem_read(base + 8)
      local peak_l   = reaper.gmem_read(base + 9)
      local peak_r   = reaper.gmem_read(base + 10)
      local phase_c  = reaper.gmem_read(base + 11)
      local ms_k     = reaper.gmem_read(base + 12)
      -- Per-track fader compensation: JSFX sees pre-fader signal.
      local fader_vol = reaper.GetMediaTrackInfo_Value(inst.track, "D_VOL")
      peak_l = peak_l * fader_vol
      peak_r = peak_r * fader_vol
      -- %.0f (not %d) on seq/n/sr: gmem_read returns Lua floats and %d errors
      -- with "no integer representation" in Reaper's Lua. %.0f emits no decimal.
      local line = string.format(
        '{"v":4,"kind":"audio","track_id":"%s","seq":%.0f,"rms":%.6f,"n":%.0f,"sr":%.0f,'
        .. '"bands":{"sub":%.6f,"low_mid":%.6f,"mid":%.6f,"high_mid":%.6f,"high":%.6f},'
        .. '"peak_l":%.6f,"peak_r":%.6f,"phase_corr":%.6f,"ms_k":%.9f}\n',
        escape_json_string(guid),
        seq, rms, n, sr,
        band_sub, band_lm, band_mid, band_hm, band_hi,
        peak_l, peak_r, phase_c, ms_k
      )
      local wr_ok, wr_err = pipe:write(line)
      if wr_ok then
        pipe:flush()
        last_seq[guid] = seq  -- commit dedup only after successful write (spec §7.3 step 2)
      else
        disconnect(wr_err)
        break  -- stop iterating; reconnect will drain on next tick.
      end
    end
  end

  reaper.defer(reap)
end

reap()
