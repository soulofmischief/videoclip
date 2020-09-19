local mpopt = require('mp.options')

-- Options can be changed here or in a separate config file.
-- Config path: ~/.config/mpv/script-opts/videoclip.conf
local config = {
    -- absolute paths
    -- relative paths (e.g. ~ for home dir) do NOT work.
    video_folder_path = string.format('%s/Videos/', os.getenv("HOME")),
    audio_folder_path = string.format('%s/Music/', os.getenv("HOME")),

    font_size = 24,

    audio_bitrate = '32k',

    -- The range of the CRF scale is 0–51, where 0 is lossless,
    -- 23 is the default, and 51 is worst quality possible.
    video_quality = 23,

    -- Use the slowest preset that you have patience for.
    -- https://trac.ffmpeg.org/wiki/Encode/H.264
    preset = 'faster',

    video_width = -2,
    video_height = 480,
}

mpopt.read_options(config, 'videoclip')
local overlay = mp.create_osd_overlay('ass-events')
local menu
local encoder
local OSD
local Timings

------------------------------------------------------------
-- utility functions

function string:endswith(suffix)
    return self:match(string.format('%s$', suffix))
end

local function add_extension(filename, extension)
    return filename .. extension
end
local function remove_extension(filename)
    return filename:gsub('%.%w+$', '')
end

local function remove_text_in_brackets(str)
    return str:gsub('%b[]', '')
end

local function remove_special_characters(str)
    return str:gsub('[%c%p%s]', '')
end

local function human_readable_time(seconds)
    if type(seconds) ~= 'number' or seconds < 0 then
        return 'empty'
    end

    local parts = {}

    parts.h = math.floor(seconds / 3600)
    parts.m = math.floor(seconds / 60) % 60
    parts.s = math.floor(seconds % 60)
    parts.ms = math.floor((seconds * 1000) % 1000)

    local ret = string.format("%02dm%02ds%03dms", parts.m, parts.s, parts.ms)

    if parts.h > 0 then
        ret = string.format('%dh%s', parts.h, ret)
    end

    return ret
end

local function construct_filename()
    local filename = mp.get_property("filename") -- filename without path

    filename = remove_extension(filename)
    filename = remove_text_in_brackets(filename)
    filename = remove_special_characters(filename)

    filename = string.format(
            '%s_(%s-%s)',
            filename,
            human_readable_time(menu.timings['start']),
            human_readable_time(menu.timings['end'])
    )

    return filename
end

local function subprocess(args)
    return mp.command_native {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }
end

------------------------------------------------------------
-- provides interface for creating audio/video clips

encoder = {}

encoder.create_videoclip = function(clip_filename)
    local clip_path = table.concat { config.video_folder_path, clip_filename, '.mp4' }
    return subprocess {
        'mpv',
        mp.get_property('path'),
        '--no-ocopy-metadata',
        '--no-sub',
        '--oac=libopus',
        '--ovc=libx264',
        '--loop-file=no',
        '--oacopts-add=vbr=on',
        '--oacopts-add=application=voip',
        '--oacopts-add=compression_level=10',
        '--oacopts-add=ac=2',
        table.concat { '--start=', menu.timings['start'] },
        table.concat { '--end=', menu.timings['end'] },
        table.concat { '--aid=', mp.get_property("aid") }, -- track number
        table.concat { '--oacopts-add=b=', config.audio_bitrate },
        table.concat { '--ovcopts-add=crf=', config.video_quality },
        table.concat { '--ovcopts-add=preset=', config.preset },
        table.concat { '--vf-add=scale=', config.video_width, ':', config.video_height },
        table.concat { '-o=', clip_path }
    }
end

encoder.create_audioclip = function(clip_filename)
    local clip_path = table.concat { config.audio_folder_path, clip_filename, '.ogg' }
    return subprocess {
        'mpv',
        mp.get_property('path'),
        '--loop-file=no',
        '--vid=no',
        '--no-ocopy-metadata',
        '--no-sub',
        '--oac=libopus',
        '--oacopts-add=vbr=on',
        '--oacopts-add=application=voip',
        '--oacopts-add=compression_level=10',
        '--oacopts-add=ac=2',
        table.concat { '--start=', menu.timings['start'] },
        table.concat { '--end=', menu.timings['end'] },
        table.concat { '--aid=', mp.get_property("aid") }, -- track number
        table.concat { '--oacopts-add=b=', config.audio_bitrate },
        table.concat { '-o=', clip_path }
    }
end

encoder.create_clip = function(clip_type)
    if clip_type == nil then
        return
    end

    if not menu.timings:validate() then
        mp.osd_message("Wrong timings. Aborting.", 2)
        return
    end

    local clip_filename = construct_filename()

    mp.osd_message("Please wait...", 9999)

    local ret
    local location

    if clip_type == 'video' then
        location = config.video_folder_path
        ret = encoder.create_videoclip(clip_filename)
    elseif clip_type == 'audio' then
        location = config.audio_folder_path
        ret = encoder.create_audioclip(clip_filename)
    end

    if ret.status == 0 then
        mp.osd_message(string.format("Clip saved to %s.", location), 2)
    else
        mp.osd_message(string.format("Error: couldn't create the clip.\nDoes %s exist?", location), 5)
    end
end

------------------------------------------------------------
-- main menu

menu = {}

menu.keybinds = {
    { key = 's', fn = function() menu.set_time('start') end },
    { key = 'e', fn = function() menu.set_time('end') end },
    { key = 'S', fn = function() menu.set_time_sub('start') end },
    { key = 'E', fn = function() menu.set_time_sub('end') end },
    { key = 'c', fn = function() menu.close(); encoder.create_clip('video'); menu.timings:reset() end },
    { key = 'a', fn = function() menu.close(); encoder.create_clip('audio'); menu.timings:reset() end },
    { key = 'o', fn = function() mp.commandv('run', 'xdg-open', 'https://streamable.com/') end },
    { key = 'ESC', fn = function() menu.close() end },
}

menu.set_time = function(property)
    menu.timings[property] = mp.get_property_number('time-pos')
    menu.update()
end

menu.set_time_sub = function(property)
    local sub_delay = mp.get_property_native("sub-delay")
    local time_pos = mp.get_property_number(string.format("sub-%s", property))

    if time_pos == nil then
        mp.osd_message("Warning: No subtitles visible.", 2)
        return
    end

    menu.timings[property] = time_pos + sub_delay
    menu.update()
end

menu.update = function()
    local osd = OSD:new():size(config.font_size):align(4)
    osd:bold('Clip creator'):newline():newline()

    osd:bold('Start time: '):append(human_readable_time(menu.timings['start'])):newline()
    osd:bold('End time: '):append(human_readable_time(menu.timings['end'])):newline()
    osd:newline()
    osd:bold('Bindings:'):newline()
    osd:tab():bold('s: '):append('Set start time'):newline()
    osd:tab():bold('e: '):append('Set end time'):newline()
    osd:newline()
    osd:tab():bold('S: '):append('Set start time based on subtitles'):newline()
    osd:tab():bold('E: '):append('Set end time based on subtitles'):newline()
    osd:newline()
    osd:tab():bold('c: '):append('Create video clip'):newline()
    osd:tab():bold('a: '):append('Create audio clip'):newline()
    osd:tab():bold('o: '):append('Open `streamable.com`'):newline()
    osd:tab():bold('ESC: '):append('Close'):newline()

    osd:draw()
end

menu.close = function()
    for _, val in pairs(menu.keybinds) do
        mp.remove_key_binding(val.key)
    end
    overlay:remove()
end

menu.open = function()
    menu.timings = Timings:new()
    for _, val in pairs(menu.keybinds) do
        mp.add_key_binding(val.key, val.key, val.fn)
    end
    menu.update()
end

------------------------------------------------------------
-- Helper class for styling OSD messages
-- http://docs.aegisub.org/3.2/ASS_Tags/

OSD = {}
OSD.__index = OSD

function OSD:new()
    return setmetatable({ text = '' }, self)
end

function OSD:append(s)
    self.text = self.text .. s
    return self
end

function OSD:bold(s)
    return self:append('{\\b1}' .. s .. '{\\b0}')
end

function OSD:newline()
    return self:append('\\N')
end

function OSD:tab()
    return self:append('\\h\\h\\h\\h')
end

function OSD:size(size)
    return self:append('{\\fs' .. size .. '}')
end

function OSD:align(number)
    return self:append('{\\an' .. number .. '}')
end

function OSD:draw()
    overlay.data = self.text
    overlay:update()
end

------------------------------------------------------------
-- Timings class

Timings = {
    ['start'] = -1,
    ['end'] = -1,
}

function Timings:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Timings:reset()
    self['start'] = -1
    self['end'] = -1
end

function Timings:validate()
    return self['start'] >= 0 and self['start'] < self['end']
end

------------------------------------------------------------
-- Validate config

if not config.video_folder_path:endswith('/') then
    config.video_folder_path = config.video_folder_path .. '/'
end

if not config.audio_folder_path:endswith('/') then
    config.audio_folder_path = config.audio_folder_path .. '/'
end

------------------------------------------------------------
-- Finally, set an 'entry point' in mpv

mp.add_key_binding('c', 'videoclip-menu-open', menu.open)
