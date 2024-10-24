local _ENV = mkmodule('plugins.preserve-rooms')

local argparse = require('argparse')
local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local GLOBAL_KEY = 'preserve-rooms'

------------------
-- command line
--

local function print_status()
    local features = preserve_rooms_getState()
    print('Features:')
    for feature,enabled in pairs(features) do
        print(('  %20s: %s'):format(feature, enabled))
    end
end

local function do_set_feature(enabled, feature)
    if not preserve_rooms_setFeature(enabled, feature) then
        qerror(('unknown feature: "%s"'):format(feature))
    end
end

local function do_reset_feature(feature)
    if not preserve_rooms_resetFeatureState(feature) then
        qerror(('unknown feature: "%s"'):format(feature))
    end
end

function parse_commandline(args)
    local opts = {}
    local positionals = argparse.processArgsGetopt(args, {
        {'h', 'help', handler=function() opts.help = true end},
    })

    if opts.help or not positionals or positionals[1] == 'help' then
        return false
    end

    local command = table.remove(positionals, 1)
    if not command or command == 'status' then
        print_status()
    elseif command == 'now' then
        preserve_rooms_cycle()
    elseif command == 'enable' or command == 'disable' then
        do_set_feature(command == 'enable', positionals[1])
    elseif command == 'reset' then
        do_reset_feature(positionals[1])
    else
        return false
    end

    return true
end

----------------------
-- ReservedWidget
--

ReservedWidget = defclass(ReservedWidget, overlay.OverlayWidget)
ReservedWidget.ATTRS{
    desc='Shows whether a zone has been reserved for a unit or role.',
    default_enabled=true,
    default_pos={x=37, y=9},
    viewscreens={
        'dwarfmode/Zone/Some/Bedroom',
        'dwarfmode/Zone/Some/DiningHall',
        'dwarfmode/Zone/Some/Office',
        'dwarfmode/Zone/Some/Tomb',
    },
    frame={w=44, h=15},
}

local new_world_loaded = true

function ReservedWidget:init()
    self.code_to_idx = {}

    self:addviews{
        widgets.Panel{
            view_id='pause_mask',
            frame={t=0, l=0, w=4, h=3},
        },
        widgets.Panel{
            view_id='add_mask',
            frame={t=3, l=4, w=4, h=3},
        },
        widgets.Panel{
            frame={t=0, l=9},
            visible=function()
                local scr = dfhack.gui.getDFViewscreen(true)
                return not dfhack.gui.matchFocusString('dwarfmode/UnitSelector', scr) and
                    not dfhack.gui.matchFocusString('dwarfmode/LocationSelector', scr)
            end,
            subviews={
                widgets.Panel{
                    visible=function()
                        return not preserve_rooms_isReserved() and preserve_rooms_getFeature('track-roles')
                    end,
                    subviews={
                        widgets.CycleHotkeyLabel{
                            view_id='role',
                            frame={t=1, l=1, r=1, h=2},
                            frame_background=gui.CLEAR_PEN,
                            label='Autoassign to holder of role:',
                            label_below=true,
                            key='CUSTOM_SHIFT_S',
                            options={{label='None', value='', pen=COLOR_YELLOW}},
                            on_change=function(code)
                                self.subviews.list:setSelected(self.code_to_idx[code] or 1)
                                preserve_rooms_assignToRole(code)
                            end,
                        },
                        widgets.Panel{
                            view_id='hover_trigger',
                            frame={t=0, l=0, r=0, h=4},
                            frame_style=gui.FRAME_MEDIUM,
                            visible=true,
                        },
                        widgets.Panel{
                            view_id='hover_expansion',
                            frame_style=gui.FRAME_MEDIUM,
                            visible=false,
                            subviews={
                                widgets.Panel{
                                    frame={t=2},
                                    frame_background=gui.CLEAR_PEN,
                                },
                                widgets.List{
                                    view_id='list',
                                    frame={t=3, l=1},
                                    frame_background=gui.CLEAR_PEN,
                                    on_submit=function(idx)
                                        self.subviews.role:setOption(idx, true)
                                    end,
                                    choices={'None'},
                                },
                            },
                        },
                    },
                },
                widgets.Panel{
                    frame={t=0, h=5},
                    frame_style=gui.FRAME_MEDIUM,
                    frame_background=gui.CLEAR_PEN,
                    visible=preserve_rooms_isReserved,
                    subviews={
                        widgets.Label{
                            frame={t=0, l=0},
                            text={
                                'Reserved for traveling unit:', NEWLINE,
                                {gap=1, text=preserve_rooms_getReservationName, pen=COLOR_YELLOW},
                            },
                        },
                        widgets.HotkeyLabel{
                            frame={t=2, l=0},
                            key='CUSTOM_SHIFT_R',
                            label='Clear reservation',
                            on_activate=preserve_rooms_clearReservation,
                        },
                    },
                },
                widgets.HelpButton{
                    command='preserve-rooms',
                    visible=function()
                        return preserve_rooms_isReserved() or preserve_rooms_getFeature('track-roles')
                    end,
                },
            },
        },
    }
end

function ReservedWidget:onInput(keys)
    if ReservedWidget.super.onInput(self, keys) then
        return true
    end
    if keys._MOUSE_L and preserve_rooms_isReserved() then
        if self.subviews.pause_mask:getMousePos() then return true end
        if self.subviews.add_mask:getMousePos() then return true end
    end
end

function ReservedWidget:render(dc)
    if new_world_loaded then
        self:refresh_role_list()
        new_world_loaded = false
    end

    local code = preserve_rooms_getRoleAssignment()
    local role = self.subviews.role
    if code ~= role:getOptionValue() then
        role:setOption(code)
        self.subviews.list:setSelected(self.code_to_idx[code] or 1)
    end

    local hover_expansion = self.subviews.hover_expansion
    if hover_expansion.visible and not hover_expansion:getMouseFramePos() then
        hover_expansion.visible = false
    elseif self.subviews.hover_trigger:getMousePos() then
        hover_expansion.visible = true
    end

    ReservedWidget.super.render(self, dc)
end

local function to_title_case(str)
    return dfhack.capitalizeStringWords(dfhack.lowerCp437(str:gsub('_', ' ')))
end

local function add_codes(codes, entity)
    if not entity then return end
    for _,role in ipairs(entity.positions.own) do
        table.insert(codes, role.code)
    end
end

local function add_options(options, choices, codes)
    for _,code in ipairs(codes) do
        local name = to_title_case(code)
        table.insert(options, {label=name, value=code, pen=COLOR_YELLOW})
        table.insert(choices, name)
    end
end

function ReservedWidget:refresh_role_list()
    local codes, options, choices = {}, {{label='None', value='', pen=COLOR_YELLOW}}, {'None'}
    add_codes(codes, df.historical_entity.find(df.global.plotinfo.civ_id));
    add_codes(codes, df.historical_entity.find(df.global.plotinfo.group_id));
    table.sort(codes)
    add_options(options, choices, codes)

    self.code_to_idx = {['']=1}
    for idx,code in ipairs(codes) do
        self.code_to_idx[code] = idx + 1 -- offset for None option
    end

    self.subviews.role.options = options
    self.subviews.role:setOption(1)
    self.subviews.list:setChoices(choices, 1)
end

OVERLAY_WIDGETS = {
    reserved=ReservedWidget,
}

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc ~= SC_MAP_LOADED or not dfhack.world.isFortressMode() then
        return
    end
    new_world_loaded = true
end

return _ENV
