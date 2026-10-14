#!/bin/sh
# System Diagnostics - Omarchy section.
#
# Validates the Omarchy desktop layer: Hyprland configuration, the shell plugin
# set, the active theme, pending migrations, menu extensions and keybindings.
# Read-only. Nothing here reloads or edits anything.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=omarchy
CHECKS=""

# ---------------------------------------------------------------- version
_ver=$(read_file /usr/share/omarchy/version)
if [ -n "$_ver" ]; then
  emit "omarchy.version" "$CAT" info 0 "Omarchy version" "$_ver" \
    "Installed Omarchy release" ""
else
  emit "omarchy.version" "$CAT" unknown 0 "Omarchy version" "unknown" \
    "/usr/share/omarchy/version could not be read" ""
fi

_channel=$(/usr/bin/omarchy channel current 2>/dev/null | /usr/bin/head -n 1)
[ -n "$_channel" ] && emit "omarchy.channel" "$CAT" info 0 "Package channel" "$_channel" \
  "Omarchy release channel" ""

# ---------------------------------------------------------------- hyprland config
if have hyprctl; then
  _cerr=$(/usr/bin/hyprctl configerrors 2>/dev/null)
  _cerr_n=$(printf '%s' "$_cerr" | /usr/bin/grep -c . 2>/dev/null)
  # hyprctl may print a single literal "ok" or a placeholder when clean.
  _cerr_clean=$(printf '%s' "$_cerr" | /usr/bin/grep -viE '^\s*$|^ok$|^no errors' | /usr/bin/head -c 4000)
  if [ -z "$_cerr_clean" ]; then
    emit "omarchy.hyprland_config" "$CAT" ok 0 "Hyprland config" "valid" \
      "hyprctl reported no configuration errors" ""
  else
    # Split each error line into a details entry.
    _d=""
    _n=0
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _d="$_d $_line"
      _n=$((_n + 1))
    done <<EOF
$_cerr_clean
EOF
    emitr "omarchy.hyprland_config" "$CAT" problem 3 "Hyprland config" "${_n} error(s)" \
      "Hyprland rejected part of its configuration" \
      "Fix the lines below, then run: hyprctl reload" \
      caution "Reload Hyprland after fixing" "hyprctl reload applies valid config; it does not fix syntax." \
      $_d
  fi

  # Plugin load errors show up in the shell journal, not hyprctl.
  _hypr_plugins=$(/usr/bin/hyprctl plugins list 2>/dev/null | /usr/bin/grep -iE 'error|fail' | /usr/bin/head -5)
  if [ -n "$_hypr_plugins" ]; then
    emit "omarchy.hyprland_plugins" "$CAT" attention 1 "Hyprland plugins" "errors" \
      "$(printf '%s' "$_hypr_plugins" | /usr/bin/tr '\n' ' ')" \
      "Inspect with: hyprctl plugins list" "hyprctl plugins list"
  fi
else
  emit "omarchy.hyprland_config" "$CAT" unknown 0 "Hyprland config" "unknown" \
    "hyprctl is not available; cannot validate the compositor configuration" ""
fi

# ---------------------------------------------------------------- keybinds
if have hyprctl && have jq; then
  _binds=$(/usr/bin/hyprctl binds -j 2>/dev/null)
  if [ -n "$_binds" ]; then
    # Conflict = same modifier+key+submap+release/longPress state, mapped to two
    # different actions (different lua arg). Mouse binds and empty keys are
    # excluded: Hyprland stores those with an empty key and they are not
    # keyboard bindings. Omarchy itself ships a couple of these (e.g. ALT+TAB),
    # so this is reported as attention, not a hard problem.
    _dups=$(printf '%s' "$_binds" | /usr/bin/jq -r '
      [ .[] | select(.mouse==false and (.key|length) > 0) ] |
      group_by(.modmask, .key, .keycode, .submap, .release, .longPress) |
      map(select( (map(.arg)|unique|length) > 1 )) |
      .[] | "modmask=\(.[0].modmask) key=\(.[0].key) submap=\(.[0].submap): " +
            ([.[].description] | join(" | "))' 2>/dev/null)
    if [ -n "$_dups" ]; then
      _d=""
      _n=0
      while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _d="$_d $_line"
        _n=$((_n + 1))
      done <<EOF
$_dups
EOF
      emitr "omarchy.keybind_conflicts" "$CAT" attention 1 "Keybind conflicts" "${_n} duplicate(s)" \
        "More than one action is bound to the same modifier+key; only one can win" \
        "Inspect with: hyprctl binds -j | jq 'group_by(.modmask,.key)|map(select(length>1))'" \
        manual "Resolve duplicate binds" "Edit the *.conf under ~/.config/hypr/ and hyprctl reload." \
        $_d
    else
      emit "omarchy.keybind_conflicts" "$CAT" ok 0 "Keybind conflicts" "none" \
        "No duplicate modifier+key bindings" ""
    fi
  else
    emit "omarchy.keybind_conflicts" "$CAT" unknown 0 "Keybind conflicts" "unknown" \
      "hyprctl binds -j produced no output" ""
  fi
fi

# ---------------------------------------------------------------- shell plugins
if have omarchy; then
  _plugs=$(/usr/bin/omarchy plugin list --json 2>/dev/null)
  if [ -n "$_plugs" ] && have jq; then
    _bad=$(printf '%s' "$_plugs" | /usr/bin/jq -r '.[] | select((.id // "") == "") | "entry without id"' 2>/dev/null)
    _failed=$(printf '%s' "$_plugs" | /usr/bin/jq -r '.[] | select(.failed == true or .error != null) | "\(.id // "?"): \(.error // "load error")"' 2>/dev/null)
    if [ -n "$_failed" ]; then
      _d=""
      while IFS= read -r _line; do [ -n "$_line" ] && _d="$_d $_line"; done <<EOF
$_failed
EOF
      emit "omarchy.shell_plugins" "$CAT" problem 3 "Shell plugins" "load errors" \
        "One or more shell plugins reported a load error" \
        "Inspect with: omarchy plugin list --json and the shell log" \
        $_d
    else
      emit "omarchy.shell_plugins" "$CAT" ok 0 "Shell plugins" "ok" \
        "Plugin list parsed without load errors" ""
    fi

    # Load failures for bar widgets are written to the user journal, not the
    # plugin list. Surface them -- a widget that failed to load is silently
    # missing, which is easy to miss.
    if have journalctl; then
      _jf=$(/usr/bin/journalctl --user -b 0 --no-pager -o cat 2>/dev/null \
        | /usr/bin/grep -iE 'Plugin (widget )?[A-Za-z0-9._-]+ failed' \
        | /usr/bin/grep -v 'angelherman.system-diagnostics' \
        | /usr/bin/sort -u | /usr/bin/head -10)
      if [ -n "$_jf" ]; then
        _d=""
        while IFS= read -r _line; do [ -n "$_line" ] && _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"; done <<EOF
$_jf
EOF
        emit "omarchy.plugin_load_failures" "$CAT" problem 3 "Plugin load failures" "this boot" \
          "A shell plugin failed to load during this boot" \
          "Read the full error: journalctl --user -b 0 | grep 'Plugin'" \
          $_d
      else
        emit "omarchy.plugin_load_failures" "$CAT" ok 0 "Plugin load failures" "none" \
          "No plugin load failures in the current boot journal" ""
      fi
    fi
  else
    emit "omarchy.shell_plugins" "$CAT" unknown 0 "Shell plugins" "unknown" \
      "omarchy plugin list --json unavailable (needs jq)" ""
  fi
else
  emit "omarchy.shell_plugins" "$CAT" unknown 0 "Shell plugins" "unknown" \
    "the omarchy command is not available on PATH" ""
fi

# ---------------------------------------------------------------- theme
# The slug lives in $HOME/.local/state/omarchy/current/theme.name; `omarchy
# theme current` only pretty-prints it. The ACTIVE files are the materialized
# merge under current/theme (a real directory, not a symlink to the source),
# so that is what must contain a usable colors.toml.
if have omarchy; then
  _theme_slug=$(read_file "$HOME/.local/state/omarchy/current/theme.name")
  _theme=$(/usr/bin/omarchy theme current 2>/dev/null | /usr/bin/head -n 1)
  _cur="$HOME/.local/state/omarchy/current/theme"
  if [ -z "$_theme_slug" ]; then
    emit "omarchy.theme" "$CAT" unknown 0 "Theme" "unknown" \
      "Could not read $HOME/.local/state/omarchy/current/theme.name" ""
  elif [ ! -d "$_cur" ]; then
    emitr "omarchy.theme" "$CAT" problem 3 "Theme" "$_theme" \
      "The active theme directory $_cur does not exist" \
      "Re-apply a theme to regenerate it: omarchy theme set '$_theme_slug'" \
      safe "Re-apply the theme" "omarchy theme set rewrites the theme's files." \
      "slug: $_theme_slug"
  elif [ ! -r "$_cur/colors.toml" ]; then
    emitr "omarchy.theme" "$CAT" attention 1 "Theme" "$_theme" \
      "The active theme is missing colors.toml at $_cur" \
      "Re-apply the theme: omarchy theme set '$_theme_slug'" \
      safe "Re-apply the theme" "omarchy theme set rewrites the theme's files." \
      "theme_dir: $_cur"
  else
    # Also confirm the source theme (user copy or system copy) still exists, so
    # a future theme switch has something to resolve.
    _src=""
    [ -d "$HOME/.config/omarchy/themes/$_theme_slug" ] && _src="$HOME/.config/omarchy/themes/$_theme_slug"
    [ -z "$_src" ] && [ -d "/usr/share/omarchy/themes/$_theme_slug" ] && _src="/usr/share/omarchy/themes/$_theme_slug"
    if [ -z "$_src" ]; then
      emitr "omarchy.theme" "$CAT" attention 1 "Theme" "$_theme" \
        "The active theme works, but its source directory was not found for '$_theme_slug'" \
        "Reinstall or re-create the theme before switching to it again" \
        manual "Reinstall the theme" "No automatic action is taken." \
        "theme_dir: $_cur"
    else
      emit "omarchy.theme" "$CAT" ok 0 "Theme" "$_theme" \
        "Active theme files are present and resolve to a source directory" \
        "theme_dir: $_cur"
    fi
  fi
fi

# ---------------------------------------------------------------- migrations
if have omarchy; then
  _mig=$(/usr/bin/omarchy migrate --pending 2>/dev/null | /usr/bin/head -20)
  if [ -n "$(printf '%s' "$_mig" | /usr/bin/grep -vE '^\s*$')" ]; then
    emitr "omarchy.migrations" "$CAT" attention 1 "Migrations" "pending" \
      "Omarchy has migrations that have not been applied" \
      "Apply them with: omarchy migrate" \
      caution "Apply pending migrations" "Runs the shipped migration steps." \
      "$(printf '%s' "$_mig" | /usr/bin/head -5 | /usr/bin/tr '\n' ' ')"
  else
    emit "omarchy.migrations" "$CAT" ok 0 "Migrations" "none pending" \
      "No pending Omarchy migrations" ""
  fi
fi

# ---------------------------------------------------------------- required commands
if have omarchy; then
  _missing=$(/usr/bin/omarchy cmd missing 2>/dev/null | /usr/bin/head -30)
  if [ -n "$(printf '%s' "$_missing" | /usr/bin/grep -vE '^\s*$')" ]; then
    emit "omarchy.required_cmds" "$CAT" attention 1 "Required commands" "missing" \
      "Some commands Omarchy expects are not installed" \
      "Install the missing packages, or inspect: omarchy cmd missing" \
      "$(printf '%s' "$_missing" | /usr/bin/tr '\n' ' ')"
  else
    emit "omarchy.required_cmds" "$CAT" ok 0 "Required commands" "present" \
      "All commands Omarchy requires are available" ""
  fi
fi

# ---------------------------------------------------------------- hooks
# Omarchy runs each non-.sample file under hooks/<name>.d/ (and hooks/<name>)
# with `bash "$hook"`, so the execute bit is NOT required and .sample files are
# deliberately inactive. The meaningful check is a syntax check: a hook with a
# bash syntax error fails silently at runtime.
_hookdir="$HOME/.config/omarchy/hooks"
if [ -d "$_hookdir" ] && have bash; then
  _bad=""
  _active=0
  for _hd in "$_hookdir"/*.d "$_hookdir"; do
    [ -d "$_hd" ] || continue
    for _h in "$_hd"/*; do
      [ -f "$_h" ] || continue
      case "$_h" in *.sample) continue ;; esac
      _active=$((_active + 1))
      _err=$(/usr/bin/bash -n "$_h" 2>&1)
      [ -n "$_err" ] && _bad="$_bad $(basename "$_hd")/$(basename "$_h")"
    done
  done
  if [ -n "$_bad" ]; then
    emitr "omarchy.hooks" "$CAT" problem 3 "Hooks" "syntax errors" \
      "Active hook scripts contain bash syntax errors and will fail when run:$_bad" \
      "Check each with: bash -n <hook>" \
      manual "Fix the hook scripts" "Edit the files under $_hookdir." \
      "hooks_dir: $_hookdir"
  else
    emit "omarchy.hooks" "$CAT" ok 0 "Hooks" "${_active} active" \
      "${_active} active hook scripts parse without errors (.sample files ignored)" ""
  fi
else
  emit "omarchy.hooks" "$CAT" info 0 "Hooks" "none" \
    "No user hooks directory at $_hookdir" ""
fi

# ---------------------------------------------------------------- menu extension
_menu="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [ -r "$_menu" ]; then
  # Strip // and /* */ comments, then validate with a JSON parser if present.
  _stripped=$(/usr/bin/sed -e 's://.*$::' -e ':a; s:/\*[^*]*\*/::g; ta' "$_menu" 2>/dev/null)
  if have jq; then
    if printf '%s' "$_stripped" | /usr/bin/jq . >/dev/null 2>&1; then
      emit "omarchy.menu_extension" "$CAT" ok 0 "Menu extension" "valid" \
        "The user menu extension is syntactically valid" ""
    else
      _err=$(printf '%s' "$_stripped" | /usr/bin/jq . 2>&1 | /usr/bin/head -3 | /usr/bin/tr '\n' ' ')
      emitr "omarchy.menu_extension" "$CAT" problem 3 "Menu extension" "invalid" \
        "The user menu extension is not valid JSONC: $_err" \
        "Fix syntax in $_menu" \
        manual "Fix the menu extension" "Edit the file; it is not modified by this plugin." \
        "path: $_menu"
    fi
  else
    emit "omarchy.menu_extension" "$CAT" info 0 "Menu extension" "present" \
      "Present but jq is unavailable to validate it" ""
  fi
else
  emit "omarchy.menu_extension" "$CAT" info 0 "Menu extension" "none" \
    "No user menu extension; Omarchy defaults are used" ""
fi

emit_json "$CAT" "$MODE"
