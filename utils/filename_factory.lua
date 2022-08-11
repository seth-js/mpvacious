--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Creates image and audio filenames compatible with Anki.
]]

local mp = require('mp')
local h = require('helpers')

local filename

local anki_compatible_length = (function()
    -- Anki forcibly mutilates all filenames longer than 119 bytes when you run `Tools->Check Media...`.
    local allowed_bytes = 119
    local timestamp_bytes = #'_99h99m99s999ms-99h99m99s999ms.webp'

    return function(str, timestamp)
        -- if timestamp provided, recalculate limit_bytes
        local limit_bytes = allowed_bytes - (timestamp and #timestamp or timestamp_bytes)

        if #str <= limit_bytes then
            return str
        end

        local bytes_per_char = h.contains_non_latin_letters(str) and #'車' or #'z'
        local limit_chars = math.floor(limit_bytes / bytes_per_char)

        if limit_chars == limit_bytes then
            return str:sub(1, limit_bytes)
        end

        local ret = h.subprocess {
            'awk',
            '-v', string.format('str=%s', str),
            '-v', string.format('limit=%d', limit_chars),
            'BEGIN{print substr(str, 1, limit); exit}'
        }

        if ret.status == 0 then
            ret.stdout = h.remove_newlines(ret.stdout)
            ret.stdout = h.remove_leading_trailing_spaces(ret.stdout)
            return ret.stdout
        else
            return 'subs2srs_' .. os.time()
        end
    end
end)()

local make_media_filename = function()
    filename = mp.get_property("filename") -- filename without path
    filename = h.remove_extension(filename)
    filename = h.remove_text_in_brackets(filename)
    filename = h.remove_special_characters(filename)
end

local make_audio_filename = function(speech_start, speech_end, extension)
    local filename_timestamp = string.format(
            '_%s-%s%s',
            h.human_readable_time(speech_start),
            h.human_readable_time(speech_end),
            extension
    )
    return anki_compatible_length(filename, filename_timestamp) .. filename_timestamp
end

local make_snapshot_filename = function(timestamp, extension)
    local filename_timestamp = string.format(
            '_%s%s',
            h.human_readable_time(timestamp),
            extension
    )
    return anki_compatible_length(filename, filename_timestamp) .. filename_timestamp
end

mp.register_event("file-loaded", make_media_filename)

return {
    make_audio_filename = make_audio_filename,
    make_snapshot_filename = make_snapshot_filename,
}
