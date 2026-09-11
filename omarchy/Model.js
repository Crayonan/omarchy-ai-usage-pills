// Pure shaping for the stable `ai-usagebar usage --json` projection.
// No provider networking, credentials, or product-specific HTTP logic lives here.

var PROVIDER_IDS = ["anthropic", "openai", "antigravity", "openrouter"]
var DEFAULT_ACCENTS = {
  anthropic: "#D97757",
  openai: "#10A37F",
  antigravity: "#4285F4",
  openrouter: "#6566F1"
}
var DEFAULT_OPACITY = 0.24

function cleanText(value, maxLength) {
  var text = value === undefined || value === null ? "" : String(value)
  text = text.replace(/[\t\r]/g, " ")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, "")
    .replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
  var limit = Number(maxLength) || 2048
  return text.length <= limit ? text : text.slice(0, limit - 1) + "…"
}

function autoTextSafe(value) {
  return cleanText(value, 1000).replace(/[\n\u2028\u2029]/g, " ")
    .replace(/</g, "‹").replace(/>/g, "›")
}

function finitePercent(value) {
  var number = Number(value)
  return isFinite(number) ? Math.max(0, Math.min(100, Math.round(number))) : null
}

function normalizeSection(raw) {
  if (!raw || typeof raw !== "object") return null
  var type = String(raw.type || "")
  if (type === "spacer") return { type: "spacer" }
  if (type === "metric") {
    var percent = finitePercent(raw.percent)
    if (percent === null) return null
    var duration = Number(raw.window_secs)
    return {
      type: "metric",
      label: cleanText(raw.label, 160),
      percent: percent,
      value: cleanText(raw.value, 240),
      detail: cleanText(raw.detail, 1000),
      severity: cleanText(raw.severity, 24),
      reset_at: cleanText(raw.reset_at, 80),
      window_secs: isFinite(duration) && duration > 0 ? duration : null
    }
  }
  if (type === "text") return {
    type: "text", label: cleanText(raw.label, 160), value: cleanText(raw.value, 1000)
  }
  if (type === "block") {
    var source = Array.isArray(raw.body) ? raw.body : []
    var body = []
    for (var i = 0; i < source.length && i < 24; i++) body.push(cleanText(source[i], 1000))
    return { type: "block", label: cleanText(raw.label, 160), body: body }
  }
  return null
}

function normalizeEntry(raw) {
  if (!raw || typeof raw !== "object") return null
  var id = cleanText(raw.id, 180).trim()
  if (!id) return null
  var sections = []
  var source = Array.isArray(raw.sections) ? raw.sections : []
  for (var i = 0; i < source.length && i < 96; i++) {
    var section = normalizeSection(source[i])
    if (section) sections.push(section)
  }
  var error = cleanText(raw.error, 1200).trim()
  return {
    id: id,
    name: cleanText(raw.name, 240),
    display_name: cleanText(raw.display_name, 240),
    plan: cleanText(raw.plan, 240),
    status: error || raw.status === "error" ? "error" : "ready",
    error: error,
    stale: raw.stale === true,
    fetched_at: cleanText(raw.fetched_at, 80),
    sections: sections
  }
}

function parseReport(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (!parsed || !Array.isArray(parsed.entries))
      return { ok: false, error: "The usage command returned an unsupported report.", entries: [] }
    var entries = []
    for (var i = 0; i < parsed.entries.length && i < 64; i++) {
      var entry = normalizeEntry(parsed.entries[i])
      if (entry) entries.push(entry)
    }
    return { ok: true, error: "", entries: entries }
  } catch (error) {
    return { ok: false, error: "The usage command returned invalid JSON.", entries: [] }
  }
}

function baseProvider(id) { return String(id || "").split("@")[0].toLowerCase() }

function entryFor(entries, providerId) {
  var list = Array.isArray(entries) ? entries : []
  for (var i = 0; i < list.length; i++)
    if (String(list[i].id).toLowerCase() === providerId) return list[i]
  for (var j = 0; j < list.length; j++)
    if (baseProvider(list[j].id) === providerId) return list[j]
  return null
}

function fiveHourMetric(entry, providerId) {
  if (!entry) return null
  var sections = entry.sections || []
  if (providerId === "antigravity") {
    var cadence = ""
    for (var i = 0; i < sections.length; i++) {
      var row = sections[i]
      if (row.type === "text" && row.value === "") cadence = row.label.toLowerCase()
      if (row.type === "metric" && row.label.toLowerCase() === "gemini"
          && (row.window_secs === 18000 || cadence === "session")) return row
    }
    return null
  }
  for (var j = 0; j < sections.length; j++) {
    var timed = sections[j]
    if (timed.type === "metric" && timed.window_secs === 18000) return timed
  }
  for (var k = 0; k < sections.length; k++) {
    var fallback = sections[k]
    var label = String(fallback.label || "").toLowerCase()
    if (fallback.type === "metric" && !/week/.test(label)
        && /(session|5\s*-?\s*h|5\s*hour)/.test(label)) return fallback
  }
  return null
}

function balanceMetric(entry) {
  if (!entry) return null
  var sections = entry.sections || []
  for (var i = 0; i < sections.length; i++)
    if (sections[i].type === "metric" && /balance/i.test(sections[i].label)) return sections[i]
  return null
}

function providerTitle(id) {
  if (id === "anthropic") return "Claude"
  if (id === "openai") return "Codex"
  if (id === "antigravity") return "Antigravity · Gemini"
  return "OpenRouter"
}

function unavailableHint(id) {
  if (id === "antigravity") return "Start Antigravity or an interactive agy session, and enable [antigravity] in ai-usagebar."
  if (id === "openrouter") return "Configure OpenRouter in ai-usagebar (OPENROUTER_API_KEY or its config file), then refresh."
  if (id === "anthropic") return "Claude did not appear in the aggregate usage report. Check the local Claude login."
  return "Codex did not appear in the aggregate usage report. Check the local Codex login."
}

function formatDuration(milliseconds) {
  if (!(milliseconds > 0)) return "now"
  var minutes = Math.max(1, Math.floor(milliseconds / 60000))
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "m"
  return minutes + "m"
}

function compactReset(resetAt, nowMs) {
  var resetMs = new Date(String(resetAt || "")).getTime()
  return isFinite(resetMs) ? formatDuration(resetMs - Number(nowMs)) : ""
}

// The backend keeps human-readable reset text for CLI consumers. The native
// panel renders a local live countdown, so remove only that duplicate fragment.
function metricDetail(row) {
  var detail = cleanText(row && row.detail, 1000)
  if (!row || !row.reset_at) return detail
  detail = detail.replace(/^Resets in [^·]+\s*(?:·\s*)?/i, "")
  detail = detail.replace(/\s*·\s*reset\s+[^·]+$/i, "")
  return detail.trim()
}

function formatUpdated(fetchedAt, nowMs) {
  var fetchedMs = new Date(String(fetchedAt || "")).getTime()
  if (!isFinite(fetchedMs)) return "Updated time unavailable"
  var elapsed = Math.max(0, Number(nowMs) - fetchedMs)
  return elapsed < 60000 ? "Updated just now" : "Updated " + formatDuration(elapsed) + " ago"
}

function providerState(providerId, entries, nowMs, loading, refreshError) {
  var entry = entryFor(entries, providerId)
  var title = providerTitle(providerId)
  var globalError = cleanText(refreshError, 500).trim()
  if (!entry) {
    return {
      id: providerId, title: title, entry: null, metric: null,
      value: loading ? "…" : "N/A", reset: "", available: false,
      stale: globalError !== "", severity: globalError ? "critical" : "low",
      message: globalError || unavailableHint(providerId), fetched: ""
    }
  }
  if (entry.status === "error") {
    return {
      id: providerId, title: title, entry: entry, metric: null,
      value: providerId === "antigravity" ? "Offline" : "N/A", reset: "", available: false,
      stale: entry.stale || globalError !== "", severity: "critical",
      message: entry.error || unavailableHint(providerId), fetched: ""
    }
  }
  var metric = providerId === "openrouter" ? balanceMetric(entry) : fiveHourMetric(entry, providerId)
  if (!metric) {
    var missing = providerId === "openrouter"
      ? "Balance data is unavailable in the current OpenRouter report."
      : (providerId === "antigravity"
          ? "The Gemini 5-hour pool is unavailable; weekly or Claude/GPT pools are not substituted."
          : "The 5-hour usage window is unavailable; no longer window is substituted.")
    return {
      id: providerId, title: title, entry: entry, metric: null,
      value: "N/A", reset: "", available: false, stale: entry.stale || globalError !== "",
      severity: globalError ? "critical" : "high", message: globalError || missing,
      fetched: entry.fetched_at
    }
  }
  return {
    id: providerId, title: title, entry: entry, metric: metric,
    value: providerId === "openrouter" ? (metric.value || "N/A") : metric.percent + "%",
    reset: providerId === "openrouter" ? "" : compactReset(metric.reset_at, nowMs),
    available: true, stale: entry.stale || globalError !== "",
    severity: globalError ? "critical" : (metric.severity || "low"),
    message: globalError ? "Refresh failed; showing the previous report. " + globalError
      : (entry.stale ? "Cached data; the provider did not supply a fresh response." : ""),
    fetched: entry.fetched_at
  }
}

function tooltip(state) {
  if (!state) return "AI usage"
  var parts = [state.title, state.value]
  if (state.reset) parts.push("resets in " + state.reset)
  if (state.stale) parts.push("stale")
  if (state.message) parts.push(state.message)
  return autoTextSafe(parts.join(" · "))
}

function validColor(value, fallback) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  return /^#[0-9a-fA-F]{6}$/.test(text) ? text.toUpperCase() : String(fallback).toUpperCase()
}

function validOpacity(value) {
  var number = Number(value)
  return isFinite(number) && number >= 0.08 && number <= 0.85 ? number : DEFAULT_OPACITY
}

function settingsWithOverrides(settings, moduleName, overrides) {
  var next = { id: String(moduleName || "bit-dev.ai-usage-pills") }
  var current = settings && typeof settings === "object" ? settings : {}
  for (var key in current)
    if (key !== "id" && key !== "__proto__" && key !== "constructor" && key !== "prototype") next[key] = current[key]
  for (var name in overrides)
    if (name !== "id" && name !== "__proto__" && name !== "constructor" && name !== "prototype") next[name] = overrides[name]
  return next
}
