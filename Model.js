// System Diagnostics -- pure formatting and classification helpers.
//
// Deliberately Qt-free: no import statements, no QML types, only plain
// functions over plain objects. That keeps every decision here unit-testable
// under node and means the panel is a renderer, not a second source of truth.
//
// The input throughout is the JSON document emitted by bin/diagnose.sh:
//   { mode, version, ts, host:{...}, sections:[...], checks:[ { id, category,
//     title, status, severity, value, detail, suggestion, details?, repair? } ] }
// and the check shape is defined by `check_json` in bin/common.sh.

// ---------------------------------------------------------------- severities

// Rank of a check status. `unknown` is ranked ABOVE `ok` on purpose: a probe
// that could not run must never leave the machine looking healthier than one
// that ran and passed. It sits just below `attention`.
var RANK = { ok: 0, info: 1, unknown: 2, attention: 3, problem: 4 }

// The four states the traffic light and the summary speak in.
function rankOf(status) {
  var r = RANK[status]
  return r === undefined ? 2 : r
}

// overallState(checks) -> "problem" | "attention" | "unknown" | "ok" | "info"
//
// Worst-wins. An empty list is "unknown", never "ok": no checks means no
// evidence, and no evidence is not health.
function overallState(checks) {
  if (!checks || checks.length === 0) return "unknown"
  var worst = 0
  for (var i = 0; i < checks.length; i++) {
    var r = rankOf(checks[i].status)
    if (r > worst) worst = r
  }
  if (worst >= RANK.problem) return "problem"
  if (worst >= RANK.attention) return "attention"
  if (worst >= RANK.unknown) return "unknown"
  if (worst >= RANK.info) return "info"
  return "ok"
}

// counts(checks) -> { problem, attention, unknown, info, ok, total }
function counts(checks) {
  var out = { problem: 0, attention: 0, unknown: 0, info: 0, ok: 0, total: 0 }
  if (!checks) return out
  for (var i = 0; i < checks.length; i++) {
    var s = checks[i].status
    if (out[s] === undefined) out[s] = 0
    out[s]++
    out.total++
  }
  return out
}

// thingsToFix(checks) -> problem + attention + unknown, worst first.
//
// These are the findings the report leads with: anything that is not a plain
// pass. `unknown` is included because "could not check" is something a reader
// needs to see, not something to bury under the passing checks.
function thingsToFix(checks) {
  var out = []
  if (!checks) return out
  for (var i = 0; i < checks.length; i++) {
    var r = rankOf(checks[i].status)
    if (r >= RANK.unknown) out.push(checks[i])
  }
  out.sort(function(a, b) {
    var d = rankOf(b.status) - rankOf(a.status)
    if (d !== 0) return d
    return String(a.id) < String(b.id) ? -1 : 1
  })
  return out
}

// ---------------------------------------------------------------- labels

function stateLabel(state) {
  switch (state) {
    case "problem":   return "Problems found"
    case "attention": return "Needs attention"
    case "unknown":   return "Could not fully check"
    case "info":      return "Informational"
    default:          return "All checks passed"
  }
}

// statusLabel(status) -> the word shown beside one finding.
function statusLabel(status) {
  switch (status) {
    case "problem":   return "Problem"
    case "attention": return "Attention"
    case "unknown":   return "Unknown"
    case "info":      return "Info"
    case "ok":        return "OK"
    default:          return status || "?"
  }
}

// A single dot glyph per status for the compact list. Solid for problems, open
// for things that are merely informational.
function statusGlyph(status) {
  switch (status) {
    case "problem":   return "\u25CF"
    case "attention": return "\u25CF"
    case "unknown":   return "\u25CB"
    case "info":      return "\u25CB"
    default:          return "\u25CF"
  }
}

// ---------------------------------------------------------------- grouping

// Display order and human names for the categories the backend emits. Unknown
// categories fall to the end under their raw id rather than disappearing.
var CATEGORY_ORDER = [
  "system", "omarchy", "systemd", "journal",
  "storage", "packages", "security", "network", "graphics"
]
var CATEGORY_LABELS = {
  system: "System",
  omarchy: "Omarchy",
  systemd: "Systemd",
  journal: "Journal",
  storage: "Storage",
  packages: "Packages",
  security: "Security",
  network: "Network",
  graphics: "Graphics"
}

function categoryLabel(cat) {
  return CATEGORY_LABELS[cat] || (cat ? String(cat) : "Other")
}

function categoryRank(cat) {
  var i = CATEGORY_ORDER.indexOf(cat)
  return i === -1 ? CATEGORY_ORDER.length : i
}

// findingRows(checks, showAll) -> a flat list the panel renders with ONE
// Repeater: section headers interleaved with their findings.
//
// showAll=false lists only things to fix, and a category with nothing to fix is
// omitted entirely (its header would be a count with no content). showAll=true
// lists every check, so the report can be read on screen too.
function findingRows(checks, showAll) {
  var rows = []
  if (!checks || checks.length === 0) return rows
  var byCat = {}
  for (var i = 0; i < checks.length; i++) {
    var c = checks[i]
    var cat = c.category || "other"
    if (!byCat[cat]) byCat[cat] = []
    byCat[cat].push(c)
  }
  var cats = Object.keys(byCat)
  cats.sort(function(a, b) {
    var d = categoryRank(a) - categoryRank(b)
    if (d !== 0) return d
    return a < b ? -1 : 1
  })
  for (var k = 0; k < cats.length; k++) {
    var cat2 = cats[k]
    var all = byCat[cat2]
    var shown = showAll ? all : thingsToFix(all)
    if (shown.length === 0) continue
    shown.sort(function(a, b) {
      var d = rankOf(b.status) - rankOf(a.status)
      if (d !== 0) return d
      return String(a.id) < String(b.id) ? -1 : 1
    })
    rows.push({
      kind: "header",
      category: cat2,
      label: categoryLabel(cat2),
      count: shown.length,
      state: overallState(all)
    })
    for (var j = 0; j < shown.length; j++) {
      rows.push({ kind: "check", check: shown[j] })
    }
  }
  return rows
}

// ---------------------------------------------------------------- time

// fmtAge(tsSec, nowSec) -> "just now" / "42s ago" / "5m ago" / "2h ago".
function fmtAge(tsSec, nowSec) {
  if (!tsSec || tsSec <= 0) return "never"
  var d = nowSec - tsSec
  if (d < 0) return "just now"
  if (d < 5) return "just now"
  if (d < 60) return d + "s ago"
  if (d < 3600) return Math.floor(d / 60) + "m ago"
  if (d < 86400) return Math.floor(d / 3600) + "h ago"
  return Math.floor(d / 86400) + "d ago"
}

function hostLine(host) {
  if (!host) return ""
  var parts = []
  if (host.os) parts.push(host.os)
  if (host.kernel) parts.push("kernel " + host.kernel)
  if (host.omarchy) parts.push("Omarchy " + host.omarchy)
  if (host.hyprland) parts.push(host.hyprland)
  return parts.join(" · ")
}

// ---------------------------------------------------------------- AI report

// buildReport(scan, opts) -> a Markdown document written to be pasted into an
// AI assistant. It is SELF-CONTAINED: it states what was scanned, what the
// verdict is, then lists every finding that is not a pass, with the exact
// evidence the backend captured. Passing checks are summarised, not enumerated,
// except in full detail mode.
function buildReport(scan, opts) {
  opts = opts || {}
  var checks = (scan && scan.checks) ? scan.checks : []
  var c = counts(checks)
  var state = overallState(checks)
  var L = []

  L.push("# System diagnostic report")
  L.push("")
  L.push("Generated by **System Diagnostics** (Omarchy bar plugin) — read-only scan.")
  L.push("")
  L.push("- **Verdict:** " + stateLabel(state))
  L.push("- **Scan mode:** " + ((scan && scan.mode) ? scan.mode : "quick"))
  L.push("- **When:** " + ((scan && scan.ts) ? new Date(scan.ts * 1000).toString() : "unknown"))
  if (scan && scan.host) {
    L.push("- **Machine:** " + (scan.host.hostname || "?") + " — " + hostLine(scan.host))
    if (scan.host.uptime) L.push("- **Uptime:** " + scan.host.uptime)
  }
  L.push("- **Checks:** " + c.total + " total — " +
    c.problem + " problem, " + c.attention + " attention, " +
    c.unknown + " unknown, " + c.info + " info, " + c.ok + " ok")
  L.push("")

  if (state === "ok" || state === "info") {
    L.push("No problems were detected in this scan.")
    L.push("")
  } else {
    L.push("## Findings")
    L.push("")
    var rows = findingRows(checks, false)
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if (r.kind === "header") {
        L.push("### " + r.label + " (" + r.count + ")")
        L.push("")
        continue
      }
      L.push.apply(L, findingBlock(r.check))
    }
  }

  if (opts.fullDetail) {
    L.push("## All checks")
    L.push("")
    for (var j = 0; j < checks.length; j++) {
      if (rankOf(checks[j].status) < RANK.unknown) {
        L.push("- [" + statusLabel(checks[j].status) + "] " +
          checks[j].title + ": " + checks[j].value +
          (checks[j].detail ? " — " + checks[j].detail : ""))
      }
    }
    L.push("")
  }

  L.push("---")
  L.push("")
  L.push("This scan is read-only: nothing was changed, restarted or repaired.")
  if (scan && scan.version) L.push("Backend version " + scan.version + ".")
  return L.join("\n")
}

// findingBlock(check) -> the Markdown lines for one finding.
function findingBlock(chk) {
  var L = []
  L.push("#### [" + statusLabel(chk.status) + "] " + chk.title +
    (chk.value ? " — " + chk.value : ""))
  L.push("")
  if (chk.detail) L.push(chk.detail)
  L.push("")
  if (chk.id) L.push("- id: `" + chk.id + "`")
  if (chk.details && chk.details.length) {
    L.push("- evidence:")
    for (var i = 0; i < chk.details.length; i++) {
      L.push("  - `" + String(chk.details[i]).replace(/`/g, "'") + "`")
    }
  }
  if (chk.suggestion) L.push("- suggested action: " + chk.suggestion)
  if (chk.repair && chk.repair.label) {
    L.push("- possible fix (" + chk.repair.tier + "): " + chk.repair.label +
      (chk.repair.detail ? " — " + chk.repair.detail : ""))
  }
  L.push("")
  return L
}

// buildPrompt(scan) -> the report wrapped in an instruction to an assistant.
function buildPrompt(scan) {
  return "You are helping me debug an Omarchy (Arch Linux) machine. " +
    "Below is a read-only diagnostic report. Identify the root cause of each " +
    "finding, rank them by real impact, and give me concrete, minimal commands " +
    "to fix them. Point out anything the report flagged that is actually " +
    "harmless, and anything important the scan could not check. Do not suggest " +
    "changing anything that is already marked OK.\n\n" + buildReport(scan, {})
}

// buildJson(scan) -> a pretty JSON snapshot, for filing or scripting.
function buildJson(scan) {
  try {
    return JSON.stringify(scan, null, 2)
  } catch (e) {
    return "{}"
  }
}

// ---------------------------------------------------------------- misc

function pluralize(n, singular, plural) {
  return n + " " + (n === 1 ? singular : (plural || singular + "s"))
}

function parseScan(raw) {
  if (!raw) return null
  try {
    var doc = JSON.parse(raw)
    if (!doc || !Array.isArray(doc.checks)) return null
    return doc
  } catch (e) {
    return null
  }
}
