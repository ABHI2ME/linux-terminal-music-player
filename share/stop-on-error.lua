local current = nil
local retry_timer = nil
local retry_id = nil

local function cancel_retry()
    if retry_timer then
        retry_timer:kill()
        retry_timer = nil
    end
    retry_id = nil
end

mp.register_event("start-file", function(event)
    local next_attempt = 1
    if current and retry_id == event.playlist_entry_id then
        next_attempt = current.attempt + 1
    end

    cancel_retry()
    current = {
        id = event.playlist_entry_id,
        attempt = next_attempt,
        handled = false
    }
end)

local function handle_failure()
    local failed = current
    if not failed or failed.handled then return end
    failed.handled = true
    mp.commandv("playlist-play-index", "none")

    if failed.attempt >= 3 then
        mp.msg.error("Attempt 3/3 failed; stopped playlist playback")
        return
    end

    mp.msg.warn(
        ("Attempt %d/3 failed; retrying the same song in 1 second")
        :format(failed.attempt)
    )

    retry_timer = mp.add_timeout(1, function()
        retry_timer = nil
        if current ~= failed then return end

        for index, entry in ipairs(mp.get_property_native("playlist", {})) do
            if entry.id == failed.id then
                retry_id = failed.id
                mp.commandv("playlist-play-index", index - 1)
                return
            end
        end

        mp.msg.warn("Retry cancelled: song is no longer in the queue")
    end)
end

mp.add_hook("on_load_fail", 50, handle_failure)

mp.register_event("end-file", function(event)
    if event.reason == "error" and current
        and current.id == event.playlist_entry_id then
        handle_failure()
    end
end)

-- Handle failure before mpv advances to another playlist entry.
mp.add_hook("on_after_end_file", 50, function() end)
mp.register_event("shutdown", cancel_retry)
