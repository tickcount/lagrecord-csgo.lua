-- Variables
local sv_maxunlag = cvar.sv_maxunlag

local host_frameticks = ffi.cast('uint32_t*', utils.opcode_scan('engine.dll', '03 05 ? ? ? ? 83 CF 10', 0x2))
local host_currentframetick = ffi.cast('uint32_t*', utils.opcode_scan('engine.dll', '2B 05 ? ? ? ? 03 05 ? ? ? ? 83 CF 10', 0x2))

-- Functions
local new_class = function()
    local mt, mt_data, this_mt = { }, { }

    mt.__metatable = false
    mt_data.struct = function(self, name)
        assert(type(name) == 'string', 'invalid class name')
        assert(rawget(self, name) == nil, 'cannot overwrite subclass')

        return function(data)
            assert(type(data) == 'table', 'invalid class data')
            rawset(self, name, setmetatable(data, {
                __metatable = false,
                __index = function(self, key)
                    return
                        rawget(mt, key) or
                        rawget(this_mt, key)
                end
            }))

            return this_mt
        end
    end

    this_mt = setmetatable(mt_data, mt)

    return this_mt
end

local insert = function(tbl, new_value)
    local new_tbl = {}

    new_tbl[#new_tbl+1] = new_value

    for _, value in pairs(tbl) do
        if value ~= nil then
            new_tbl[#new_tbl+1] = value
        end
    end

    return new_tbl
end

local evnt do (function()
    local c_list = { }

    local function register_callback(fn)
        assert(type(fn) == 'function', 'callback has to be a function')

        local already_exists = false

        for _, this in pairs(c_list) do
            if this == fn then
                already_exists = true
                break
            end
        end

        if already_exists then
            error('the function callback is already registered', 3)
        end

        table.insert(c_list, fn)
    end

    local function unregister_callback(fn)
        assert(type(fn) == 'function', 'callback has to be a function')

        for index, this in pairs(c_list) do
            if this == fn then
                table.remove(c_list, index)

                return true
            end
        end

        return false
    end

    local function get_list()
        return c_list
    end

    local function fire_callback(...)
        local output = false

        for idx, callback in ipairs(c_list) do
            local success, result = pcall(callback, ...)

            if success == true and result == true then
                output = true
                break
            end
        end

        return output
    end

    evnt = {
        register = register_callback,
        unregister = unregister_callback,
        fire_callback = fire_callback,
        get_list = get_list
    }
end)() end

-- Global Class
local ctx = new_class()
    :struct 'lagrecord' {
        data = { },

        estimated_tickbase = 0,
        local_player_tickbase = 0,

        purge = function(self, player)
            if player == nil then
                self.estimated_tickbase = 0
                self.local_player_tickbase = 0
                self.data = { }

                return
            end

            self.data[player:get_index()] = { }
        end,

        track_time = function(self, cmd)
            self.estimated_tickbase = globals.estimated_tickbase

            if cmd.choked_commands == 0 then
                self.local_player_tickbase = entity.get_local_player().m_nTickBase
            end
        end,

        get_server_time = function(self, as_ticks)
            local predicted_server_tick = globals.client_tick + globals.clock_offset

            if host_frameticks ~= nil and host_currentframetick ~= nil then
                local delta = host_frameticks[0] - host_currentframetick[0]
                local max_delta_for_tick_rate = math.floor(1 / globals.tickinterval) / 8

                if delta > 0 and delta < max_delta_for_tick_rate then
                    predicted_server_tick = predicted_server_tick + delta
                end
            end

            return as_ticks ~= true and to_time(predicted_server_tick) or predicted_server_tick
        end,

        get_player_time = function(self, player, as_tick)
            assert(player ~= nil and player.get_simulation_time ~= nil, 'invalid player')

            if player == entity.get_local_player() then
                local m_nTickBase = self.local_player_tickbase -- player.m_nTickBase

                return as_tick ~= true and to_time(m_nTickBase) or m_nTickBase
            end

            local simulation_time = player:get_simulation_time().current

            return as_tick == true and
                self:to_ticks(simulation_time) or simulation_time
        end,

        get_dead_time = function(self, as_tick)
            local sv_maxunlag = sv_maxunlag:float()
            local outgoing_latency = utils.net_channel().latency[0]
            local dead_time = to_time(self.estimated_tickbase) - outgoing_latency - sv_maxunlag

            return as_tick == true and to_ticks(dead_time) or dead_time
        end,

        verify_records = function(self, userptr, dead_time, is_alive)
            if  userptr == nil or
                userptr.records == nil or userptr.localdata == nil then
                return
            end

            -- make sure we dont keep old records if those become invalid
            local records, localdata = userptr.records, userptr.localdata
            local first_rec_origin = records[1] and records[1].origin
            local allow_updates = localdata.allow_updates

            for idx, this in ipairs(records) do
                local c_idx = idx ~= 1

                if allow_updates == false then
                    c_idx = true
                end

                if is_alive == false then
                    rawset(records, idx, nil)
                elseif c_idx == true and first_rec_origin then
                    if this.simulation_time <= dead_time then
                        -- purge current record if simulation time is too old
                        rawset(records, idx, nil)
                    elseif first_rec_origin:distsqr(this.origin) > 4096 then
                        -- purge records if teleport distance is too big
                        for i=2, #records do
                            rawset(records, i, nil)
                        end

                        break
                    end
                end
            end
        end,

        on_net_update = function(self, player, tick, dead_time)
            assert(player ~= nil and player.get_simulation_time ~= nil, 'invalid player')

            local index = player:get_index()
            local origin = player:get_origin()
            local is_alive = player:is_alive()

            self.data[index] = self.data[index] or new_class()
                :struct 'records' { }
                :struct 'localdata' {
                    allow_updates = false,
                    updated_this_frame = false,
                    last_animated_simulation = 0,
                    no_entry = vector(),
                    cycle = 0
                }

            -- preserve data
            local user = self.data[index]
            local records, localdata = user.records, user.localdata
            local simulation_time = self:get_player_time(player)

            -- set update state to false
            localdata.allow_updates = evnt.fire_callback(player)
            localdata.updated_this_frame = false

            if  localdata.allow_updates == false or
                is_alive == false or player:is_dormant() == true then
                goto verify_records
            end

            do
                local shifted_forwards = records[1] and
                    math.max(0, to_ticks(records[1].simulation_time - simulation_time)) or 0

                if shifted_forwards > 0 and localdata.no_entry.x == 0 then
                    localdata.no_entry.y = shifted_forwards
                elseif shifted_forwards <= 0 then
                    localdata.no_entry.y = 0
                end

                localdata.cycle = records[1] and math.max(0, tick - records[1].tick - 1) or 0
                localdata.no_entry.x = shifted_forwards
                localdata.last_animated_simulation = simulation_time

                if records[1] and simulation_time <= records[1].simulation_time then
                    goto verify_records
                end

                -- STAGE: PLAYER_UPDATE
                localdata.updated_this_frame = true

                rawset(user, 'records', insert(records, {
                    tick = tick,
                    shifting = to_ticks(simulation_time) - tick - 1,
                    elapsed = math.clamp(records[1] and (tick - records[1].tick - 1) or 0, 0, 72),
                    choked = math.clamp(records[1] and (to_ticks(simulation_time - records[1].simulation_time) - 1) or 0, 0, 72),

                    origin = origin,
                    origin_old = records[1] and records[1].origin or origin,
                    simulation_time = simulation_time,
                    simulation_time_old = records[1] and records[1].simulation_time or simulation_time,

                    angles = player:get_angles(),
                    eye_position = player:get_eye_position(),
                    volume = { player.m_vecMins, player.m_vecMaxs }
                }))

                -- invoke entity update callback
                events.entity_update:call {
                    tick = tick,
                    index = index,
                    entity = player
                }
            end

            ::verify_records::

            self:verify_records(user, dead_time, is_alive)
        end
    }

    :struct 'output' {
        get_player_idx = function(self, ...)
            local va = { ... }

            if #va == 0 then
                local me = entity.get_local_player()

                if me == nil then
                    return
                end

                return me:get_index()
            end

            local va = va[1]
            local va_type = type(va)

            if va == nil or va_type == 'nil' then
                return
            end

            if va_type == 'userdata' and va.get_index then
                return va:get_index()
            end

            if va_type == 'userdata' or va_type == 'cdata' or va_type == 'number' then
                local player = entity.get(va)

                if player == nil then
                    return
                end

                return player:get_index()
            end

            return nil
        end,

        get_player_data = function(self, ...)
            local index = self:get_player_idx(...)

            if index == nil then
                return
            end

            local data = self.lagrecord.data[index]

            if data == nil or data.localdata == nil or data.records == nil then
                return
            end

            return data
        end,

        get_all = function(self, ...)
            local data = self:get_player_data(...)

            if data == nil then
                return
            end

            return data.records
        end,

        get_record = function(self, ...)
            local data = self:get_player_data(...)

            if data == nil then
                return
            end

            return data.records[({ ... })[2] or 1]
        end,

        get_snapshot = function(self, ...)
            local data = self:get_player_data(...)

            if data == nil then
                return
            end

            local record_at = ({ ... })[2] or 1
            local record = data.records[record_at]

            if record == nil then
                return
            end

            return {
                id = record_at,
                tick = record.tick,
                updated_this_frame = data.localdata.updated_this_frame,

                origin = {
                    angles = record.angles,
                    volume = record.volume,
                    current = record.origin,
                    previous = record.origin_old,
                    change = record.origin:distsqr(record.origin_old)
                },

                simulation_time = {
                    animated = data.localdata.last_animated_simulation,
                    current = record.simulation_time,
                    previous = record.simulation_time_old,
                    change = record.simulation_time - record.simulation_time_old
                },

                command = {
                    elapsed = record.elapsed,
                    choke = record.choked,
                    cycle = data.localdata.cycle,
                    shifting = record.shifting,
                    no_entry = data.localdata.no_entry,
                }
            }, record
        end,

        get_server_time = function(self, ...)
            return self.lagrecord:get_server_time(...)
        end
    }

-- Callbacks
events.level_init:set(function() ctx.lagrecord:purge() end)
events.createmove:set(function(cmd) ctx.lagrecord:track_time(cmd) end)
events.net_update_end:set(function()
    local lagrecord = ctx.lagrecord

    local me = entity.get_local_player()
    local tick = lagrecord:get_server_time(true)
    local dead_time = lagrecord:get_dead_time(false)

    if me == nil or globals.is_in_game == false then
        lagrecord:purge()
        return
    end

    if me:is_alive() == false then
        lagrecord.estimated_tickbase = globals.client_tick + globals.clock_offset
    end

    entity.get_players(false, true, function(player)
        lagrecord:on_net_update(player, tick, dead_time)
    end)
end)

return {
    set_update_callback = function(...)
        return evnt.register(...)
    end,

    unset_update_callback = function(...)
        return evnt.unregister(...)
    end,

    get_player_data = function(...)
        return ctx.output:get_player_data(...)
    end,

    get_all = function(...)
        return ctx.output:get_all(...)
    end,

    get_record = function(...)
        return ctx.output:get_record(...)
    end,

    get_snapshot = function(...)
        return ctx.output:get_snapshot(...)
    end,

    get_server_time = function(...)
        return ctx.output:get_server_time(...)
    end
}
