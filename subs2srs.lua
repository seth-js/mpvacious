--[[
Copyright (C) 2020-2022 Ren Tatsumoto and contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

Requirements:
* mpv >= 0.32.0
* AnkiConnect
* curl
* xclip (when running X11)
* wl-copy (when running Wayland)

Usage:
1. Change `config` according to your needs
* Config path: ~/.config/mpv/script-opts/subs2srs.conf
* Config file isn't created automatically.

2. Open a video

3. Use key bindings to manipulate the script
* Open mpvacious menu - `a`
* Create a note from the current subtitle line - `Ctrl + e`

For complete usage guide, see <https://github.com/Ajatt-Tools/mpvacious/blob/master/README.md>
]]

local config = {
    -- Common
    autoclip = false, -- enable copying subs to the clipboard when mpv starts
    nuke_spaces = false, -- remove all spaces from exported anki cards
    clipboard_trim_enabled = true, -- remove unnecessary characters from strings before copying to the clipboard
    use_ffmpeg = false, -- if set to true, use ffmpeg to create audio clips and snapshots. by default use mpv.
    snapshot_format = "webp", -- webp or jpg
    snapshot_quality = 15, -- from 0=lowest to 100=highest
    snapshot_width = -2, -- a positive integer or -2 for auto
    snapshot_height = 200, -- same
    screenshot = false, -- create a screenshot instead of a snapshot; see example config.
    audio_format = "opus", -- opus or mp3
    audio_bitrate = "18k", -- from 16k to 32k
    audio_padding = 0.12, -- Set a pad to the dialog timings. 0.5 = audio is padded by .5 seconds. 0 = disable.
    tie_volumes = false, -- if set to true, the volume of the outputted audio file depends on the volume of the player at the time of export
    preview_audio = true, -- play created audio clips in background.

    -- Menu
    menu_font_name = "Noto Serif CJK JP",
    menu_font_size = 25,
    show_selected_text = true,

    -- Custom encoding args
    ffmpeg_audio_args = '-af silenceremove=1:0:-50dB',
    mpv_audio_args = '--af-append=silenceremove=1:0:-50dB',

    -- Anki
    create_deck = false, -- automatically create a deck for new cards
    allow_duplicates = false, -- allow making notes with the same sentence field
    deck_name = "Learning", -- name of the deck for new cards
    model_name = "Japanese sentences", -- Tools -> Manage note types
    sentence_field = "SentKanji",
    secondary_field = "SentEng",
    audio_field = "SentAudio",
    image_field = "Image",
    append_media = true, -- True to append video media after existing data, false to insert media before
    disable_gui_browse = false, -- Lets you disable anki browser manipulation by mpvacious.

    -- Note tagging
    -- The tag(s) added to new notes. Spaces separate multiple tags.
    -- Change to "" to disable tagging completely.
    -- The following substitutions are supported:
    --   %n - the name of the video
    --   %t - timestamp
    --   %d - episode number (if none found, returns nothing)
    --   %e - SUBS2SRS_TAGS environment variable
    note_tag = "subs2srs %n",
    tag_nuke_brackets = true, -- delete all text inside brackets before substituting filename into tag
    tag_nuke_parentheses = false, -- delete all text inside parentheses before substituting filename into tag
    tag_del_episode_num = true, -- delete the episode number if found
    tag_del_after_episode_num = true, -- delete everything after the found episode number (does nothing if tag_del_episode_num is disabled)
    tag_filename_lowercase = false, -- convert filename to lowercase for tagging.

    -- Misc info
    miscinfo_enable = true,
    miscinfo_field = "Notes", -- misc notes and source information field
    miscinfo_format = "%n EP%d (%t)", -- format string to use for the miscinfo_field, accepts note_tag-style format strings

    -- Forvo support
    use_forvo = "yes", -- 'yes', 'no', 'always'
    vocab_field = "VocabKanji", -- target word field
    vocab_audio_field = "VocabAudio", -- target word audio
}

-- Defines config profiles
-- Each name references a file in ~/.config/mpv/script-opts/*.conf
-- Profiles themselves are defined in ~/.config/mpv/script-opts/subs2srs_profiles.conf
local profiles = {
    profiles = "subs2srs,subs2srs_english",
    active = "subs2srs",
}

local mp = require('mp')
local utils = require('mp.utils')
local msg = require('mp.msg')
local OSD = require('osd_styler')
local config_manager = require('config')
local encoder = require('encoder')
local h = require('helpers')
local Menu = require('menu')
local clip_autocopy = require('utils.clip_autocopy')
local timings = require('utils.timings')
local filename_factory = require('utils.filename_factory')
local switch = require('utils.switch')
local play_control = require('utils.play_control')
local Subtitle = require('subtitles.subtitle')
local sub_list = require('subtitles.sub_list')

-- namespaces
local subs
local ankiconnect
local menu
local platform
local append_forvo_pronunciation

------------------------------------------------------------
-- utility functions

local function maybe_remove_all_spaces(str)
    if config.nuke_spaces == true and h.contains_non_latin_letters(str) then
        return str:gsub('%s*', '')
    else
        return str
    end
end

local function escape_for_osd(str)
    str = h.trim(str)
    str = str:gsub('[%[%]{}]', '')
    return str
end

local function copy_to_clipboard(_, text)
    if not h.is_empty(text) then
        text = config.clipboard_trim_enabled and h.trim(text) or h.remove_newlines(text)
        platform.copy_to_clipboard(text)
    end
end

local function copy_sub_to_clipboard()
    copy_to_clipboard("copy-on-demand", mp.get_property("sub-text"))
end

local codec_support = (function()
    local ovc_help = h.subprocess { 'mpv', '--ovc=help' }
    local oac_help = h.subprocess { 'mpv', '--oac=help' }

    local function is_audio_supported(codec)
        return oac_help.status == 0 and oac_help.stdout:match('--oac=' .. codec) ~= nil
    end

    local function is_image_supported(codec)
        return ovc_help.status == 0 and ovc_help.stdout:match('--ovc=' .. codec) ~= nil
    end

    return {
        snapshot = {
            libwebp = is_image_supported('libwebp'),
            mjpeg = is_image_supported('mjpeg'),
        },
        audio = {
            libmp3lame = is_audio_supported('libmp3lame'),
            libopus = is_audio_supported('libopus'),
        },
    }
end)()

local function ensure_deck()
    if config.create_deck == true then
        ankiconnect.create_deck(config.deck_name)
    end
end

local function load_next_profile()
    config_manager.next_profile()
    ensure_deck()
    h.notify("Loaded profile " .. profiles.active)
end

local function tag_format(filename)
    filename = h.remove_extension(filename)
    filename = h.remove_common_resolutions(filename)

    local s, e, episode_num = h.get_episode_number(filename)

    if config.tag_del_episode_num == true and not h.is_empty(s) then
        if config.tag_del_after_episode_num == true then
            -- Removing everything (e.g. episode name) after the episode number including itself.
            filename = filename:sub(1, s)
        else
            -- Removing the first found instance of the episode number.
            filename = filename:sub(1, s) .. filename:sub(e + 1, -1)
        end
    end

    if config.tag_nuke_brackets == true then
        filename = h.remove_text_in_brackets(filename)
    end
    if config.tag_nuke_parentheses == true then
        filename = h.remove_filename_text_in_parentheses(filename)
    end

    if config.tag_filename_lowercase == true then
        filename = filename:lower()
    end

    filename = h.remove_leading_trailing_spaces(filename)
    filename = filename:gsub(" ", "_")
    filename = filename:gsub("_%-_", "_") -- Replaces garbage _-_ substrings with a underscore
    filename = h.remove_leading_trailing_dashes(filename)
    return filename, episode_num or ''
end

local function substitute_fmt(tag)
    local filename, episode = tag_format(mp.get_property("filename"))

    local function substitute_filename(_tag)
        return _tag:gsub("%%n", filename)
    end

    local function substitute_episode_number(_tag)
        return _tag:gsub("%%d", episode)
    end

    local function substitute_time_pos(_tag)
        local time_pos = h.human_readable_time(mp.get_property_number('time-pos'))
        return _tag:gsub("%%t", time_pos)
    end

    local function substitute_envvar(_tag)
        local env_tags = os.getenv('SUBS2SRS_TAGS') or ''
        return _tag:gsub("%%e", env_tags)
    end

    tag = substitute_filename(tag)
    tag = substitute_episode_number(tag)
    tag = substitute_time_pos(tag)
    tag = substitute_envvar(tag)
    tag = h.remove_leading_trailing_spaces(tag)

    return tag
end

local function construct_note_fields(sub_text, secondary_text, snapshot_filename, audio_filename)
    local ret = {
        [config.sentence_field] = sub_text,
    }
    if not h.is_empty(config.secondary_field) then
        ret[config.secondary_field] = secondary_text
    end
    if not h.is_empty(config.image_field) then
        ret[config.image_field] = string.format('<img alt="snapshot" src="%s">', snapshot_filename)
    end
    if not h.is_empty(config.audio_field) then
        ret[config.audio_field] = string.format('[sound:%s]', audio_filename)
    end
    if config.miscinfo_enable == true then
        ret[config.miscinfo_field] = substitute_fmt(config.miscinfo_format)
    end
    return ret
end

local function join_media_fields(new_data, stored_data)
    for _, field in pairs { config.audio_field, config.image_field, config.miscinfo_field } do
        if not h.is_empty(field) then
            new_data[field] = h.table_get(stored_data, field, "") .. h.table_get(new_data, field, "")
        end
    end
    return new_data
end

local function update_sentence(new_data, stored_data)
    -- adds support for TSCs
    -- https://tatsumoto-ren.github.io/blog/discussing-various-card-templates.html#targeted-sentence-cards-or-mpvacious-cards
    -- if the target word was marked by yomichan, this function makes sure that the highlighting doesn't get erased.

    if h.is_empty(stored_data[config.sentence_field]) then
        -- sentence field is empty. can't continue.
        return new_data
    elseif h.is_empty(new_data[config.sentence_field]) then
        -- *new* sentence field is empty, but old one contains data. don't delete the existing sentence.
        new_data[config.sentence_field] = stored_data[config.sentence_field]
        return new_data
    end

    local _, opentag, target, closetag, _ = stored_data[config.sentence_field]:match('^(.-)(<[^>]+>)(.-)(</[^>]+>)(.-)$')
    if target then
        local prefix, _, suffix = new_data[config.sentence_field]:match(table.concat { '^(.-)(', target, ')(.-)$' })
        if prefix and suffix then
            new_data[config.sentence_field] = table.concat { prefix, opentag, target, closetag, suffix }
        end
    end
    return new_data
end

local function audio_padding()
    local video_duration = mp.get_property_number('duration')
    if config.audio_padding == 0.0 or not video_duration then
        return 0.0
    end
    if subs.user_timings.is_set('start') or subs.user_timings.is_set('end') then
        return 0.0
    end
    return config.audio_padding
end

------------------------------------------------------------
-- front for adding and updating notes

local function export_to_anki(gui)
    local sub = subs.get()
    if sub == nil then
        h.notify("Nothing to export.", "warn", 1)
        return
    end

    if not gui and h.is_empty(sub['text']) then
        sub['text'] = string.format("mpvacious wasn't able to grab subtitles (%s)", os.time())
    end
    local snapshot_timestamp = mp.get_property_number("time-pos", 0)
    local snapshot_filename = filename_factory.make_snapshot_filename(snapshot_timestamp, config.snapshot_extension)
    local audio_filename = filename_factory.make_audio_filename(sub['start'], sub['end'], config.audio_extension)

    encoder.create_snapshot(snapshot_timestamp, snapshot_filename)
    encoder.create_audio(sub['start'], sub['end'], audio_filename, audio_padding())

    local note_fields = construct_note_fields(sub['text'], sub['secondary'], snapshot_filename, audio_filename)
    ankiconnect.add_note(note_fields, gui)
    subs.clear()
end

local function update_last_note(overwrite)
    local sub = subs.get()
    local last_note_id = ankiconnect.get_last_note_id()

    if sub == nil then
        h.notify("Nothing to export. Have you set the timings?", "warn", 2)
        return
    elseif h.is_empty(sub['text']) then
        -- In this case, don't modify whatever existing text there is and just
        -- modify the other fields we can. The user might be trying to add
        -- audio to a card which they've manually transcribed (either the video
        -- has no subtitles or it has image subtitles).
        sub['text'] = nil
    end

    if last_note_id < h.minutes_ago(10) then
        h.notify("Couldn't find the target note.", "warn", 2)
        return
    end

    local snapshot_timestamp = mp.get_property_number("time-pos", 0)
    local snapshot_filename = filename_factory.make_snapshot_filename(snapshot_timestamp, config.snapshot_extension)
    local audio_filename = filename_factory.make_audio_filename(sub['start'], sub['end'], config.audio_extension)

    local create_media = function()
        encoder.create_snapshot(snapshot_timestamp, snapshot_filename)
        encoder.create_audio(sub['start'], sub['end'], audio_filename, audio_padding())
    end

    local new_data = construct_note_fields(sub['text'], sub['secondary'], snapshot_filename, audio_filename)
    local stored_data = ankiconnect.get_note_fields(last_note_id)
    if stored_data then
        new_data = append_forvo_pronunciation(new_data, stored_data)
        new_data = update_sentence(new_data, stored_data)
        if not overwrite then
            if config.append_media then
                new_data = join_media_fields(new_data, stored_data)
            else
                new_data = join_media_fields(stored_data, new_data)
            end
        end
    end

    -- If the text is still empty, put some dummy text to let the user know why
    -- there's no text in the sentence field.
    if h.is_empty(new_data[config.sentence_field]) then
        new_data[config.sentence_field] = string.format("mpvacious wasn't able to grab subtitles (%s)", os.time())
    end

    ankiconnect.append_media(last_note_id, new_data, create_media)
    subs.clear()
end

------------------------------------------------------------
-- seeking: sub replay, sub seek, sub rewind

local function _(params)
    return function()
        return pcall(h.unpack(params))
    end
end

------------------------------------------------------------
-- platform specific

local function init_platform_windows()
    local self = {}
    local curl_tmpfile_path = utils.join_path(os.getenv('TEMP'), 'curl_tmp.txt')
    mp.register_event('shutdown', function()
        os.remove(curl_tmpfile_path)
    end)

    self.tmp_dir = function()
        return os.getenv('TEMP')
    end

    self.copy_to_clipboard = function(text)
        text = text:gsub("&", "^^^&"):gsub("[<>|]", "")
        mp.commandv("run", "cmd.exe", "/d", "/c", string.format("@echo off & chcp 65001 >nul & echo %s|clip", text))
    end

    self.curl_request = function(request_json, completion_fn)
        local handle = io.open(curl_tmpfile_path, "w")
        handle:write(request_json)
        handle:close()
        local args = {
            'curl',
            '-s',
            'localhost:8765',
            '-H',
            'Content-Type: application/json; charset=UTF-8',
            '-X',
            'POST',
            '--data-binary',
            table.concat { '@', curl_tmpfile_path }
        }
        return h.subprocess(args, completion_fn)
    end

    self.windows = true

    return self
end

local function init_platform_nix()
    local self = {}
    local clip = (function()
        if h.is_mac() then
            return 'LANG=en_US.UTF-8 pbcopy'
        elseif h.is_wayland() then
            return 'wl-copy'
        else
            return 'xclip -i -selection clipboard'
        end
    end)()

    self.tmp_dir = function()
        return '/tmp'
    end

    self.copy_to_clipboard = function(text)
        local handle = io.popen(clip, 'w')
        handle:write(text)
        handle:close()
    end

    self.curl_request = function(request_json, completion_fn)
        local args = { 'curl', '-s', 'localhost:8765', '-X', 'POST', '-d', request_json }
        return h.subprocess(args, completion_fn)
    end

    return self
end

platform = h.is_win() and init_platform_windows() or init_platform_nix()

------------------------------------------------------------
-- utils for downloading pronunciations from Forvo

do
    local base64d -- http://lua-users.org/wiki/BaseSixtyFour
    do
        local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        base64d = function(data)
            data = string.gsub(data, '[^' .. b .. '=]', '')
            return (data:gsub('.', function(x)
                if (x == '=') then return '' end
                local r, f = '', (b:find(x) - 1)
                for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
                return r;
            end)        :gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
                if (#x ~= 8) then return '' end
                local c = 0
                for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end
                return string.char(c)
            end))
        end
    end

    local function url_encode(url)
        -- https://gist.github.com/liukun/f9ce7d6d14fa45fe9b924a3eed5c3d99
        local char_to_hex = function(c)
            return string.format("%%%02X", string.byte(c))
        end
        if url == nil then
            return
        end
        url = url:gsub("\n", "\r\n")
        url = url:gsub("([^%w _%%%-%.~])", char_to_hex)
        url = url:gsub(" ", "+")
        return url
    end

    local function reencode(source_path, dest_path)
        local args = {
            'mpv',
            source_path,
            '--loop-file=no',
            '--video=no',
            '--no-ocopy-metadata',
            '--no-sub',
            '--audio-channels=mono',
            '--oacopts-add=vbr=on',
            '--oacopts-add=application=voip',
            '--oacopts-add=compression_level=10',
            '--af-append=silenceremove=1:0:-50dB',
            table.concat { '--oac=', config.audio_codec },
            table.concat { '--oacopts-add=b=', config.audio_bitrate },
            table.concat { '-o=', dest_path }
        }
        return h.subprocess(args)
    end

    local function reencode_and_store(source_path, filename)
        local reencoded_path = utils.join_path(platform.tmp_dir(), 'reencoded_' .. filename)
        reencode(source_path, reencoded_path)
        local result = ankiconnect.store_file(filename, reencoded_path)
        os.remove(reencoded_path)
        return result
    end

    local function curl_save(source_url, save_location)
        local curl_args = { 'curl', source_url, '-s', '-L', '-o', save_location }
        return h.subprocess(curl_args).status == 0
    end

    local function get_pronunciation_url(word)
        local file_format = config.audio_extension:sub(2)
        local forvo_page = h.subprocess { 'curl', '-s', string.format('https://forvo.com/search/%s/ja', url_encode(word)) }.stdout
        local play_params = string.match(forvo_page, "Play%((.-)%);")

        if play_params then
            local iter = string.gmatch(play_params, "'(.-)'")
            local formats = { mp3 = iter(), ogg = iter() }
            return string.format('https://audio00.forvo.com/%s/%s', file_format, base64d(formats[file_format]))
        end
    end

    local function make_forvo_filename(word)
        return string.format('forvo_%s%s', platform.windows and os.time() or word, config.audio_extension)
    end

    local function get_forvo_pronunciation(word)
        local audio_url = get_pronunciation_url(word)

        if h.is_empty(audio_url) then
            msg.warn(string.format("Seems like Forvo doesn't have audio for word %s.", word))
            return
        end

        local filename = make_forvo_filename(word)
        local tmp_filepath = utils.join_path(platform.tmp_dir(), filename)

        local result
        if curl_save(audio_url, tmp_filepath) and reencode_and_store(tmp_filepath, filename) then
            result = string.format('[sound:%s]', filename)
        else
            msg.warn(string.format("Couldn't download audio for word %s from Forvo.", word))
        end

        os.remove(tmp_filepath)
        return result
    end

    append_forvo_pronunciation = function(new_data, stored_data)
        if config.use_forvo == 'no' then
            -- forvo functionality was disabled in the config file
            return new_data
        end

        if type(stored_data[config.vocab_audio_field]) ~= 'string' then
            -- there is no field configured to store forvo pronunciation
            return new_data
        end

        if h.is_empty(stored_data[config.vocab_field]) then
            -- target word field is empty. can't continue.
            return new_data
        end

        if config.use_forvo == 'always' or h.is_empty(stored_data[config.vocab_audio_field]) then
            local forvo_pronunciation = get_forvo_pronunciation(stored_data[config.vocab_field])
            if not h.is_empty(forvo_pronunciation) then
                if config.vocab_audio_field == config.audio_field then
                    -- improperly configured fields. don't lose sentence audio
                    new_data[config.audio_field] = forvo_pronunciation .. new_data[config.audio_field]
                else
                    new_data[config.vocab_audio_field] = forvo_pronunciation
                end
            end
        end

        return new_data
    end
end

------------------------------------------------------------
-- AnkiConnect requests

ankiconnect = {}

ankiconnect.execute = function(request, completion_fn)
    -- utils.format_json returns a string
    -- On error, request_json will contain "null", not nil.
    local request_json, error = utils.format_json(request)

    if error ~= nil or request_json == "null" then
        return completion_fn and completion_fn()
    else
        return platform.curl_request(request_json, completion_fn)
    end
end

ankiconnect.parse_result = function(curl_output)
    -- there are two values that we actually care about: result and error
    -- but we need to crawl inside to get them.

    if curl_output == nil then
        return nil, "Failed to format json or no args passed"
    end

    if curl_output.status ~= 0 then
        return nil, "Ankiconnect isn't running"
    end

    local stdout_json = utils.parse_json(curl_output.stdout)

    if stdout_json == nil then
        return nil, "Fatal error from Ankiconnect"
    end

    if stdout_json.error ~= nil then
        return nil, tostring(stdout_json.error)
    end

    return stdout_json.result, nil
end

ankiconnect.store_file = function(filename, file_path)
    local args = {
        action = "storeMediaFile",
        version = 6,
        params = {
            filename = filename,
            path = file_path
        }
    }

    local ret = ankiconnect.execute(args)
    local _, error = ankiconnect.parse_result(ret)
    if not error then
        msg.info(string.format("File stored: '%s'.", filename))
        return true
    else
        msg.error(string.format("Couldn't store file '%s': %s", filename, error))
        return false
    end
end

ankiconnect.create_deck = function(deck_name)
    local args = {
        action = "changeDeck",
        version = 6,
        params = {
            cards = {},
            deck = deck_name
        }
    }
    local result_notify = function(_, result, _)
        local _, error = ankiconnect.parse_result(result)
        if not error then
            msg.info(string.format("Deck %s: check completed.", deck_name))
        else
            msg.warn(string.format("Deck %s: check failed. Reason: %s.", deck_name, error))
        end
    end
    ankiconnect.execute(args, result_notify)
end

ankiconnect.add_note = function(note_fields, gui)
    local action = gui and 'guiAddCards' or 'addNote'
    local tags = h.is_empty(config.note_tag) and {} or { substitute_fmt(config.note_tag) }
    local args = {
        action = action,
        version = 6,
        params = {
            note = {
                deckName = config.deck_name,
                modelName = config.model_name,
                fields = note_fields,
                options = {
                    allowDuplicate = config.allow_duplicates,
                    duplicateScope = "deck",
                },
                tags = tags,
            }
        }
    }
    local result_notify = function(_, result, _)
        local note_id, error = ankiconnect.parse_result(result)
        if not error then
            h.notify(string.format("Note added. ID = %s.", note_id))
        else
            h.notify(string.format("Error: %s.", error), "error", 2)
        end
    end
    ankiconnect.execute(args, result_notify)
end

ankiconnect.get_last_note_id = function()
    local ret = ankiconnect.execute {
        action = "findNotes",
        version = 6,
        params = {
            query = "added:1" -- find all notes added today
        }
    }

    local note_ids, _ = ankiconnect.parse_result(ret)

    if not h.is_empty(note_ids) then
        return h.max_num(note_ids)
    else
        return -1
    end
end

ankiconnect.get_note_fields = function(note_id)
    local ret = ankiconnect.execute {
        action = "notesInfo",
        version = 6,
        params = {
            notes = { note_id }
        }
    }

    local result, error = ankiconnect.parse_result(ret)

    if error == nil then
        result = result[1].fields
        for key, value in pairs(result) do
            result[key] = value.value
        end
        return result
    else
        return nil
    end
end

ankiconnect.gui_browse = function(query)
    if config.disable_gui_browse then
        return
    end
    ankiconnect.execute {
        action = 'guiBrowse',
        version = 6,
        params = {
            query = query
        }
    }
end

ankiconnect.add_tag = function(note_id, tag)
    if not h.is_empty(tag) then
        tag = substitute_fmt(tag)
        ankiconnect.execute {
            action = 'addTags',
            version = 6,
            params = {
                notes = { note_id },
                tags = tag
            }
        }
    end
end

ankiconnect.append_media = function(note_id, fields, create_media_fn)
    -- AnkiConnect will fail to update the note if it's selected in the Anki Browser.
    -- https://github.com/FooSoft/anki-connect/issues/82
    -- Switch focus from the current note to avoid it.
    ankiconnect.gui_browse("nid:1") -- impossible nid

    local args = {
        action = "updateNoteFields",
        version = 6,
        params = {
            note = {
                id = note_id,
                fields = fields,
            }
        }
    }

    local on_finish = function(_, result, _)
        local _, error = ankiconnect.parse_result(result)
        if not error then
            create_media_fn()
            ankiconnect.add_tag(note_id, config.note_tag)
            ankiconnect.gui_browse(string.format("nid:%s", note_id)) -- select the updated note in the card browser
            h.notify(string.format("Note #%s updated.", note_id))
        else
            h.notify(string.format("Error: %s.", error), "error", 2)
        end
    end

    ankiconnect.execute(args, on_finish)
end

------------------------------------------------------------
-- subtitles and timings

subs = {
    dialogs = sub_list.new(),
    user_timings = timings.new(),
    observed = false
}

subs.get_timing = function(position)
    if subs.user_timings.is_set(position) then
        return subs.user_timings.get(position)
    elseif not subs.dialogs.is_empty() then
        return subs.dialogs.get_time(position)
    end
    return -1
end

subs.get = function()
    if subs.dialogs.is_empty() then
        subs.dialogs.insert(Subtitle:now())
    end
    local sub = Subtitle:new {
        ['text'] = subs.dialogs.get_text(false),
        ['secondary'] = subs.dialogs.get_text(true),
        ['start'] = subs.get_timing('start'),
        ['end'] = subs.get_timing('end'),
    }
    if sub['start'] < 0 or sub['end'] < 0 then
        return nil
    end
    if sub['start'] == sub['end'] then
        return nil
    end
    if sub['start'] > sub['end'] then
        sub['start'], sub['end'] = sub['end'], sub['start']
    end
    if not h.is_empty(sub['text']) then
        sub['text'] = h.trim(sub['text'])
        sub['text'] = h.escape_special_characters(sub['text'])
        sub['text'] = maybe_remove_all_spaces(sub['text'])
    end
    return sub
end

subs.append = function()
    if subs.dialogs.insert(Subtitle:now()) then
        menu:update()
    end
end

subs.observe = function()
    mp.observe_property("sub-text", "string", subs.append)
    subs.observed = true
end

subs.unobserve = function()
    mp.unobserve_property(subs.append)
    subs.observed = false
end

subs.set_timing_to_sub = function(position)
    local sub = Subtitle:now()
    if sub then
        subs.user_timings.set(position, sub[position])
        h.notify(h.capitalize_first_letter(position) .. " time has been set.")
        if not subs.observed then
            subs.observe()
        end
    else
        h.notify("There's no visible subtitle.", "info", 2)
    end
end

subs.set_timing = function(position)
    subs.user_timings.set(position, mp.get_property_number('time-pos'))
    h.notify(h.capitalize_first_letter(position) .. " time has been set.")
    if not subs.observed then
        subs.observe()
    end
end

subs.set_starting_line = function()
    subs.clear()
    if Subtitle:now() then
        subs.observe()
        h.notify("Timings have been set to the current sub.", "info", 2)
    else
        h.notify("There's no visible subtitle.", "info", 2)
    end
end

subs.clear = function()
    subs.unobserve()
    subs.dialogs = sub_list.new()
    subs.user_timings = timings.new()
end

subs.clear_and_notify = function()
    subs.clear()
    h.notify("Timings have been reset.", "info", 2)
end



------------------------------------------------------------
-- main menu

menu = Menu:new {
    hints_state = switch.new { 'hidden', 'menu', 'global', },
}

menu.keybindings = {
    { key = 'S', fn = menu:with_update { subs.set_timing_to_sub, 'start' } },
    { key = 'E', fn = menu:with_update { subs.set_timing_to_sub, 'end' } },
    { key = 's', fn = menu:with_update { subs.set_timing, 'start' } },
    { key = 'e', fn = menu:with_update { subs.set_timing, 'end' } },
    { key = 'c', fn = menu:with_update { subs.set_starting_line } },
    { key = 'r', fn = menu:with_update { subs.clear_and_notify } },
    { key = 'g', fn = menu:with_update { export_to_anki, true } },
    { key = 'n', fn = menu:with_update { export_to_anki, false } },
    { key = 'm', fn = menu:with_update { update_last_note, false } },
    { key = 'M', fn = menu:with_update { update_last_note, true } },
    { key = 't', fn = menu:with_update { clip_autocopy.toggle } },
    { key = 'i', fn = menu:with_update { menu.hints_state.bump } },
    { key = 'p', fn = menu:with_update { load_next_profile } },
    { key = 'ESC', fn = function() menu:close() end },
    { key = 'q', fn = function() menu:close() end },
}

function menu:print_header(osd)
    osd:submenu('mpvacious options'):newline()
    osd:item('Timings: '):text(h.human_readable_time(subs.get_timing('start')))
    osd:item(' to '):text(h.human_readable_time(subs.get_timing('end'))):newline()
    osd:item('Clipboard autocopy: '):text(clip_autocopy.is_enabled()):newline()
    osd:item('Active profile: '):text(profiles.active):newline()
    osd:item('Deck: '):text(config.deck_name):newline()
end

function menu:print_bindings(osd)
    if self.hints_state.get() == 'global' then
        osd:submenu('Global bindings'):newline()
        osd:tab():item('ctrl+c: '):text('Copy current subtitle to clipboard'):newline()
        osd:tab():item('ctrl+h: '):text('Seek to the start of the line'):newline()
        osd:tab():item('ctrl+shift+h: '):text('Replay current subtitle'):newline()
        osd:tab():item('shift+h/l: '):text('Seek to the previous/next subtitle'):newline()
        osd:tab():item('alt+h/l: '):text('Seek to the previous/next subtitle and pause'):newline()
        osd:italics("Press "):item('i'):italics(" to hide bindings."):newline()
    elseif self.hints_state.get() == 'menu' then
        osd:submenu('Menu bindings'):newline()
        osd:tab():item('c: '):text('Set timings to the current sub'):newline()
        osd:tab():item('s: '):text('Set start time to current position'):newline()
        osd:tab():item('e: '):text('Set end time to current position'):newline()
        osd:tab():item('shift+s: '):text('Set start time to current subtitle'):newline()
        osd:tab():item('shift+e: '):text('Set end time to current subtitle'):newline()
        osd:tab():item('r: '):text('Reset timings'):newline()
        osd:tab():item('n: '):text('Export note'):newline()
        osd:tab():item('g: '):text('GUI export'):newline()
        osd:tab():item('m: '):text('Update the last added note '):italics('(+shift to overwrite)'):newline()
        osd:tab():item('t: '):text('Toggle clipboard autocopy'):newline()
        osd:tab():item('p: '):text('Switch to next profile'):newline()
        osd:tab():item('ESC: '):text('Close'):newline()
        osd:italics("Press "):item('i'):italics(" to show global bindings."):newline()
    else
        osd:italics("Press "):item('i'):italics(" to show menu bindings."):newline()
    end
end

function menu:warn_formats(osd)
    if config.use_ffmpeg then
        return
    end
    for type, codecs in pairs(codec_support) do
        for codec, supported in pairs(codecs) do
            if not supported and config[type .. '_codec'] == codec then
                osd:red('warning: '):newline()
                osd:tab():text(string.format("your version of mpv does not support %s.", codec)):newline()
                osd:tab():text(string.format("mpvacious won't be able to create %s files.", type)):newline()
            end
        end
    end
end

function menu:print_legend(osd)
    osd:new_layer():size(config.menu_font_size):font(config.menu_font_name):align(4)
    self:print_header(osd)
    self:print_bindings(osd)
    self:warn_formats(osd)
end

function menu:print_selection(osd)
    if subs.observed and config.show_selected_text then
        osd:new_layer():size(config.menu_font_size):font(config.menu_font_name):align(6)
        osd:submenu("Selected text"):newline()
        for _, s in ipairs(subs.dialogs.get_subs_list()) do
            osd:text(escape_for_osd(s['text'])):newline()
        end
    end
end

function menu:make_osd()
    local osd = OSD:new()
    self:print_legend(osd)
    self:print_selection(osd)
    return osd
end

------------------------------------------------------------
-- main

local main = (function()
    local main_executed = false
    return function()
        if main_executed then
            return
        else
            main_executed = true
        end

        config_manager.init(config, profiles)
        encoder.init(config, ankiconnect.store_file, platform.tmp_dir)
        clip_autocopy.init(config.autoclip, copy_to_clipboard)
        ensure_deck()

        -- Key bindings
        mp.add_forced_key_binding("Ctrl+n", "mpvacious-export-note", export_to_anki)
        mp.add_forced_key_binding("Ctrl+c", "mpvacious-copy-sub-to-clipboard", copy_sub_to_clipboard)
        mp.add_key_binding("Ctrl+t", "mpvacious-autocopy-toggle", clip_autocopy.toggle)

        -- Open advanced menu
        mp.add_key_binding("a", "mpvacious-menu-open", function() menu:open() end)

        -- Note updating
        mp.add_key_binding("Ctrl+m", "mpvacious-update-last-note", _ { update_last_note, false })
        mp.add_key_binding("Ctrl+M", "mpvacious-overwrite-last-note", _ { update_last_note, true })

        -- Vim-like seeking between subtitle lines
        mp.add_key_binding("H", "mpvacious-sub-seek-back", _ { play_control.sub_seek, 'backward' })
        mp.add_key_binding("L", "mpvacious-sub-seek-forward", _ { play_control.sub_seek, 'forward' })

        mp.add_key_binding("Alt+h", "mpvacious-sub-seek-back-pause", _ { play_control.sub_seek, 'backward', true })
        mp.add_key_binding("Alt+l", "mpvacious-sub-seek-forward-pause", _ { play_control.sub_seek, 'forward', true })

        mp.add_key_binding("Ctrl+h", "mpvacious-sub-rewind", _ { play_control.sub_rewind })
        mp.add_key_binding("Ctrl+H", "mpvacious-sub-replay", _ { play_control.play_till_sub_end })
        mp.add_key_binding("Ctrl+L", "mpvacious-sub-play-up-to-next", _ { play_control.play_till_next_sub_end })
    end
end)()

mp.register_event("file-loaded", main)
