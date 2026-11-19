-- /etc/fluent-bit/logtide.lua — map journald fields to LogTide's log schema
-- LogTide entry: time, service, level, message, metadata
local levels = { [0]="critical", [1]="critical", [2]="critical", [3]="error",
                 [4]="warn", [5]="info", [6]="info", [7]="debug" }

function to_logtide(tag, ts, r)
  local prio = tonumber(r["PRIORITY"] or 6) or 6
  local is_container = r["CONTAINER_NAME"] ~= nil
  local out = {
    service = r["CONTAINER_NAME"] or r["SYSLOG_IDENTIFIER"] or r["_SYSTEMD_UNIT"] or "unknown",
    level   = levels[prio] or "info",
    message = r["MESSAGE"] or "",
    metadata = {
      host         = r["_HOSTNAME"],
      source       = is_container and "docker" or "journal",
      unit         = r["_SYSTEMD_UNIT"],
      ident        = r["SYSLOG_IDENTIFIER"],
      container_id = r["CONTAINER_ID"],
      image        = r["IMAGE_NAME"],
      pid          = r["_PID"],
      uid          = r["_UID"],
      comm         = r["_COMM"],
      priority     = prio
    }
  }
  return 2, ts, out   -- 2 = record replaced, timestamp kept
end
