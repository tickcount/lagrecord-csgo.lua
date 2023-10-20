# lagrecord.lua
A lagrecord library for Neverlose CS:GO that supports multiple essential HvH features.

Since the CS:GO is likely going to die in about 2 months I decided to no longer gatekeep some of my projects so the [pasters](https://i.imgur.com/giH9W2E.png) can finally learn something from it.

## Issues
1. this library is almost 2 years old and some tenchniques / implementations may be outdated.
2. get_dead_time function is mostly wrong and needs to be done correctly. [See this](https://www.unknowncheats.me/forum/counterstrike-global-offensive/359885-fldeadtime-int.html).
3. in some cases it may preserve records that are already invalid (eg. post dormant, etc...)

## Information
If you dont need an entire library just to check if the local player is currently under the defensive effect:
```Lua
local max_tickbase = 0

local function on_createmove(cmd)
    local me = entity.get_local_player()
    local tickbase = me.m_nTickBase

    if math.abs(tickbase - max_tickbase) > 64 then
        -- nullify highest tickbase if the difference is too big
        max_tickbase = 0
    end

    local defensive_ticks_left = 0

    -- defensive effect can be achieved because the lag compensation is made so that
    -- it doesn't write records if the current simulation time is less than/equals highest acknowledged simulation time
    -- https://gitlab.com/KittenPopo/csgo-2018-source/-/blame/main/game/server/player_lagcompensation.cpp#L723

    if tickbase > max_tickbase then
        max_tickbase = tickbase
    elseif max_tickbase > tickbase then
        defensive_ticks_left = math.min(14, math.max(0, max_tickbase-tickbase-1))
    end

    print_dev(defensive_ticks_left)
end

events.createmove(on_createmove)
```

## Example
```Lua
local lagrecord = require 'lagrecord'

lagrecord.set_update_callback(function(player)
    if player == entity.get_local_player() then
        -- return true to force the library to write entries for the local player
        return true
    end
end)

events.createmove(function()
    local me = entity.get_local_player()

    local snapshot = lagrecord.get_snapshot(me)

    if snapshot == nil then
        return
    end

    local shifting = snapshot.command.shifting
    local defensive = snapshot.command.no_entry

    print_dev(string.format(
        'records: %d | shifting: %d | defensive: [current: %d / max: %d]',
        #lagrecord.get_all(me),
        shifting,
        defensive.x, defensive.y
    ))
end)
```

## Keys
**`lagrecord.get_snapshot(entity/entity_index)`**
```
{
    id,
    tick,
    updated_this_frame,

    origin = {
        angles,
        volume,
        current,
        previous,
        change
    },

    simulation_time = {
        animated,
        current,
        previous,
        change
    },

    command = {
        elapsed,
        choke,
        cycle,
        shifting,
        no_entry
    }
}
```
---

* I don't think it's necessary to document other functions/features, get_snapshot should be fine for most things. 
* You can require this library in neverlose via require 'neverlose/lagrecord'

```Lua
local lagrecord do
	lagrecord = require 'neverlose/lagrecord'
	lagrecord = lagrecord^lagrecord.SIGNED
end
```
