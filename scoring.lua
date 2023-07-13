scoring_config = scoring_config or {}
scoring_config.bomb_check_interval_seconds = scoring_config.bomb_check_interval_seconds or 0.01
scoring_config.defaut_scoring = scoring_config.default_scoring or {
    falloff = 'stepped',
    thresholds = {
        [5] = 100,
        [21] = 50,
        [30] = 30,
        [45] = 10,
        [60] = 0
    }
}
scoring_config.zones = scoring_config.zones or {}

-- #region Leaderboard

local leaderboard = {
    guided = {},
    unguided = {}
}

local function noop() end

local menu = missionCommands.addSubMenu('Leaderboards')
local menu_guided = missionCommands.addSubMenu('Guided Bombs', menu)
local menu_unguided = missionCommands.addSubMenu('Unguided Bombs', menu)

missionCommands.addCommand('--- no entries --', menu_guided, noop)
missionCommands.addCommand('--- no entries --', menu_unguided, noop)


local function sort_by_score(a, b) 
    return a.score > b.score 
end

local function update_menu(path, entries)
    if #entries == 0 then
        missionCommands.addCommand('--- no entries --', path, noop)
        return
    end

    for i, entry in ipairs(entries) do
        missionCommands.addCommand(string.format('%i: %s, %i p, %i shots', i, entry.player, entry.score, entry.shots), path, noop)
    end
end

local function update_leaderboard(player, score, weapon_desc)
    local board = weapon_desc.guidance and leaderboard.guided or leaderboard.unguided
    local found = false

    for _, entry in ipairs(board) do
        if entry.player == player then
            entry.score = entry.score + score
            entry.shots = entry.shots + 1
            found = true
        end
    end

    if not found then
        local entry = {
            player = player,
            score = score,
            shots = 1
        }

        table.insert(board, entry)
        table.sort(board, sort_by_score)
    end

    missionCommands.removeItem(menu_guided)
    missionCommands.removeItem(menu_unguided)

    menu_guided = missionCommands.addSubMenu('Guided Bombs', menu)
    menu_unguided = missionCommands.addSubMenu('Unguided Bombs', menu)

    update_menu(menu_guided, leaderboard.guided)
    update_menu(menu_unguided, leaderboard.unguided)
end

-- #endregion

-- #region Scoring

local function get_distance(a, b)
    local x = b.x - a.x
    local y = b.y - a.y
    local z = b.z - a.z

    return math.sqrt(math.pow(x, 2) + math.pow(y, 2) + math.pow(z, 2))
end

local function sort_thresholds(scoring)
    local sorted_thresholds = {}
    for d, s in pairs(scoring.thresholds) do
        table.insert(sorted_thresholds, { max_distance = d, max_score = s })
    end

    table.sort(sorted_thresholds, function (a, b) return a.max_score > b.max_score end)

    return sorted_thresholds
end


local function get_score_stepped_falloff(scoring, distance)
    local sorted_thresholds = sort_thresholds(scoring)

    for _, threshold in ipairs(sorted_thresholds) do
        local max_distance = threshold.max_distance
        local max_score = threshold.max_score

        if distance <= max_distance then
            return max_score
        end
    end

    return 0
end

local function get_score_linear_falloff(scoring, distance)
    local sorted_thresholds = sort_thresholds(scoring)

    local prev_distance = nil
    local prev_score = nil

    for _, threshold in ipairs(sorted_thresholds) do
        local max_distance = threshold.max_distance
        local max_score = threshold.max_score

        if distance <= max_distance then

            if prev_score == nil then
                return max_score
            end

            local slope = (max_score - prev_score) / (max_distance - prev_distance)
            local offset = max_score - (slope * max_distance)

            return slope * distance + offset
        end

        prev_distance = max_distance
        prev_score = max_score
    end

    return 0
end

local function get_score(scoring, distance)
    local score = 0

    if type(scoring.falloff) == 'function' then
        score = scoring.falloff(scoring, distance)
    elseif scoring.falloff == 'linear' then
        score = get_score_linear_falloff(scoring, distance)
    else
        score = get_score_stepped_falloff(scoring, distance)
    end

    -- There is no built-in round function
    -- this is a workaround found at 
    -- https://stackoverflow.com/questions/18313171/lua-rounding-numbers-and-then-truncate
    return math.floor(score + 0.5)
end

-- #endregion

-- #region Bomb Tracking

local function track_bomb(state, time)
    if state.weapon:isExist() then
        state.point = state.weapon:getPoint()
        return time + scoring_config.bomb_check_interval_seconds
    end

    state.point.y = 0

    for _, zone_config in pairs(scoring_config.zones) do
        local name = type(zone_config) == 'string' and zone_config or zone_config.name
        local zone = trigger.misc.getZone(name)

        if zone and zone.point and zone.radius then
            local distance = get_distance(state.point, zone.point)

            if distance <= zone.radius then
                local scoring = zone_config.scoring or scoring_config.defaut_scoring
                local score = get_score(scoring, distance)
                local msg = string.format(
                    '%s hit target %s with %s!\nDistance: %.2f m / %.2f ft\nScore: %i',
                    state.player, name, state.weapon_desc.displayName, distance, distance * 3.28084, score
                )

                trigger.action.outText(msg, 10)
                update_leaderboard(state.player, score, state.weapon_desc)
            end
        end
    end

    return nil
end

local function handle_shot(event)
    if not event.initiator or not event.weapon then
        return
    end

    local player = event.initiator:getPlayerName()

    if not player then
        return
    end

    local weapon_desc = event.weapon:getDesc()

    if weapon_desc.category ~= Weapon.Category.BOMB then 
        return
    end

    local state = { 
        weapon = event.weapon,
        weapon_desc = weapon_desc,
        player = player
    }

    timer.scheduleFunction(track_bomb, state, timer.getTime() + scoring_config.bomb_check_interval_seconds)
end

-- #endregion

local event_handlers = {
    [world.event.S_EVENT_SHOT] = { handle_shot },
}

function event_handlers:onEvent(event)
    if not event_handlers[event.id] then
        return
    end

    local handlers = event_handlers[event.id]

    for i = 1, #handlers do
        handlers[i](event)
    end
end

world.addEventHandler(event_handlers)

