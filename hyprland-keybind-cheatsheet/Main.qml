import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI
import qs.Services.Compositor

Item {
  id: root
  property var pluginApi: null


  Component.onCompleted: {
    if (pluginApi && !parserStarted) {
      checkAndParse();
    }
  }

  onPluginApiChanged: {
    if (pluginApi && !parserStarted) {
      checkAndParse();
    }
  }

  // Check if compositor changed since last parse, and re-parse if needed
  function checkAndParse() {
    var currentCompositor = getCurrentCompositor();
    var savedCompositor = pluginApi?.pluginSettings?.detectedCompositor || "";
    var hasData = (pluginApi?.pluginSettings?.cheatsheetData || []).length > 0;

    // Re-parse if:
    // 1. No data cached yet, OR
    // 2. Compositor changed since last parse
    if (!hasData || currentCompositor !== savedCompositor) {
      parserStarted = true;
      runParser();
    } else {
      parserStarted = true; // Mark as done, using cache
    }
  }

  // Get current compositor name
  function getCurrentCompositor() {
    if (CompositorService.isHyprland) return "hyprland";
    return "unknown";
  }

  function getUnsupportedCompositorMessage(compositor) {
    var messages = {
      "niri": {
        short: pluginApi?.tr("keybind-cheatsheet.error.niri-not-supported") || "Niri is not yet supported",
        detail: pluginApi?.tr("keybind-cheatsheet.error.niri-detail") || "Niri support may be added in a future update"
      },
      "sway": {
        short: pluginApi?.tr("keybind-cheatsheet.error.sway-not-supported") || "Sway is not yet supported",
        detail: pluginApi?.tr("keybind-cheatsheet.error.sway-detail") || "Sway support may be added in a future update (similar format to Hyprland)"
      },
      "labwc": {
        short: pluginApi?.tr("keybind-cheatsheet.error.labwc-not-supported") || "LabWC is not supported",
        detail: pluginApi?.tr("keybind-cheatsheet.error.labwc-detail") || "LabWC uses XML config format which is incompatible with this plugin"
      },
      "mango": {
        short: pluginApi?.tr("keybind-cheatsheet.error.mango-not-supported") || "MangoWC is not supported",
        detail: pluginApi?.tr("keybind-cheatsheet.error.mango-detail") || "MangoWC config format is not compatible with this plugin"
      },
      "unknown": {
        short: pluginApi?.tr("keybind-cheatsheet.error.unknown-compositor") || "Unknown compositor detected",
        detail: pluginApi?.tr("keybind-cheatsheet.error.unknown-detail") || "This plugin only supports Hyprland compositor"
      }
    };
    return messages[compositor] || messages["unknown"];
  }

  property bool parserStarted: false

  // Memory leak prevention: cleanup on destruction
  Component.onDestruction: {
    clearParsingData();
    cleanupProcesses();
  }

  function cleanupProcesses() {
    if (hyprGlobProcess.running) hyprGlobProcess.running = false;
    if (hyprReadProcess.running) hyprReadProcess.running = false;

    hyprGlobProcess.expandedFiles = [];
    currentLines = [];
  }

  function clearParsingData() {
    filesToParse = [];
    parsedFiles = {};
    accumulatedLines = [];
    currentLines = [];
    collectedBinds = {};
    parseDepthCounter = 0;
  }

  // Refresh function - accessible from mainInstance
  function refresh() {
    if (!pluginApi) {
      return;
    }

    // Reset parserStarted to allow re-parsing
    parserStarted = false;
    isCurrentlyParsing = false;

    // Now run parser
    parserStarted = true;
    runParser();
  }

  // Recursive parsing support
  property var filesToParse: []
  property var parsedFiles: ({})
  property var accumulatedLines: []
  property var currentLines: []
  property var collectedBinds: ({})  // Collect keybinds from all files

  // Memory leak prevention: recursion limits
  property int maxParseDepth: 50
  property int parseDepthCounter: 0
  property bool isCurrentlyParsing: false

  function runParser() {
    if (isCurrentlyParsing) {
      return;
    }

    isCurrentlyParsing = true;
    parseDepthCounter = 0;

    var compositorName = getCurrentCompositor();
    if (!CompositorService.isHyprland) {
      isCurrentlyParsing = false;

      var unsupportedMsg = getUnsupportedCompositorMessage(compositorName);
      saveToDb([{
        "title": pluginApi?.tr("keybind-cheatsheet.error.unsupported-compositor") || "Unsupported Compositor",
        "binds": [
          { "keys": compositorName.toUpperCase(), "desc": unsupportedMsg.short },
          { "keys": "INFO", "desc": unsupportedMsg.detail }
        ]
      }]);
      return;
    }

    var homeDir = Quickshell.env("HOME");
    if (!homeDir) {
      isCurrentlyParsing = false;
      saveToDb([{
        "title": "ERROR",
        "binds": [{ "keys": "ERROR", "desc": "Cannot get $HOME" }]
      }]);
      return;
    }

    filesToParse = [];
    parsedFiles = {};
    accumulatedLines = [];
    collectedBinds = {};

    var filePath = pluginApi?.pluginSettings?.hyprlandKeybindConfigPath || (homeDir + "/.config/hypr/hyprland.conf");
    filePath = filePath.replace(/^~/, homeDir);

    hyprReadProcess.command = ["/usr/bin/cat", filePath];
    hyprReadProcess.running = true;
  }

  Process {
    id: hyprReadProcess
    running: false

    stdout: SplitParser {
      onRead: data => {
        if (root.accumulatedLines.length < 10000) {
          root.accumulatedLines.push(data);
        }
      }
    }

    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0 && root.accumulatedLines.length > 0) {
        root.parseHyprlandConfig(root.accumulatedLines.join("\n"));
      }
      root.accumulatedLines = [];
      root.isCurrentlyParsing = false;
    }
  }

  function parseHyprlandConfig(text) {
    var lines = text.split('\n');
    var categories = [];
    var currentCategory = null;
    var hasCategories = false; // Track if we found any category headers

    // Submap state
    var currentSubmap = null;
    var submapTriggers = {};

    // TUTAJ ZMIANA: Pobierz ustawioną zmienną (domyślnie $mod) i zamień na wielkie litery
    var modVar = pluginApi?.pluginSettings?.modKeyVariable || "$mod";
    var modVarUpper = modVar.toUpperCase();

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();

      // Submap detection
      if (line.startsWith("submap =")) {
        var sub = line.split('=')[1].trim();
        if (sub === "reset") {
          currentSubmap = null;
        } else {
          currentSubmap = sub;
        }
      }

      // Category header: # 1. Category Name
      if (line.startsWith("#") && line.match(/#\s*\d+\./)) {
        hasCategories = true; // Found at least one category
        if (currentCategory) {
          categories.push(currentCategory);
        }
        var title = line.replace(/#\s*\d+\.\s*/, "").trim();
        currentCategory = { "title": title, "binds": [] };
      }
      // Keybind: bind = $mod, T, exec, cmd #"description"
      else if (line.includes("bind") && line.includes('#"')) {
        // If no categories found yet, create default category
        if (!currentCategory && !hasCategories) {
          var defaultCategoryName = pluginApi?.tr("keybind-cheatsheet.default-category") || "Keybinds";
          currentCategory = { "title": defaultCategoryName, "binds": [] };
        }

        if (currentCategory) {
          var descMatch = line.match(/#"(.*?)"$/);
          var description = descMatch ? descMatch[1] : "No description";

          var parts = line.split(',');
          if (parts.length >= 2) {
            var modPart = (parts[0].split('=')[1] || "").trim().toUpperCase();
            var rawKey = parts[1].trim().toUpperCase();
            var key = formatSpecialKey(rawKey);

            // Build modifiers list properly
            var mods = [];
            // TUTAJ ZMIANA: Sprawdzamy czy to ustawiony mod (np. $MAINMOD) albo SUPER
            if (modPart.includes(modVarUpper) || modPart.includes("SUPER")) mods.push("Super");

            if (modPart.includes("SHIFT")) mods.push("Shift");
            if (modPart.includes("CTRL") || modPart.includes("CONTROL")) mods.push("Ctrl");
            if (modPart.includes("ALT")) mods.push("Alt");
            // Detect submap trigger - check if "submap" is the dispatcher (first word in action)
            var actionPart = parts.slice(2).join(',').trim();
            var isSubmapTrigger = actionPart.startsWith("submap") && !actionPart.startsWith("submap ");
            if (isSubmapTrigger) {
              var submapMatch = line.match(/submap,\s*([A-Za-z0-9_-]+)/i);
              if (submapMatch) {
                var submapName = submapMatch[1];
                var triggerKey;
                if (mods.length > 0) {
                  triggerKey = mods.join(" + ") + " + " + key;
                } else {
                  triggerKey = key;
                }
                submapTriggers[submapName] = triggerKey;
              }
              continue; // Skip the trigger line itself
            }

            // Build full key string
            var fullKey;

            // Build chained key for submap (SUPER + A, SHIFT + N)
            if (currentSubmap && submapTriggers[currentSubmap]) {
              var triggerKey = submapTriggers[currentSubmap];
              if (mods.length > 0) {
                fullKey = triggerKey + ", " + mods.join(" + ") + " + " + key;
              } else {
                fullKey = triggerKey + ", " + key;
              }
            } else if (mods.length > 0) {
              fullKey = mods.join(" + ") + " + " + key;
            } else {
              fullKey = key;
            }

            // Skip binds inside submap - just show submap keys
            if (currentSubmap) {
              currentCategory.binds.push({
                "keys": fullKey,
                "desc": description
              });
              continue;
            }

            currentCategory.binds.push({
              "keys": fullKey,
              "desc": description
            });
          }
        }
      }
    }

    if (currentCategory) {
      categories.push(currentCategory);
    }

    saveToDb(categories);
    isCurrentlyParsing = false;
    clearParsingData();
  }

  function formatSpecialKey(key) {
    var keyMap = {
      "XF86AUDIORAISEVOLUME": "Vol Up",
      "XF86AUDIOLOWERVOLUME": "Vol Down",
      "XF86AUDIOMUTE": "Mute",
      "XF86AUDIOMICMUTE": "Mic Mute",
      "XF86AUDIOPLAY": "Play",
      "XF86AUDIOPAUSE": "Pause",
      "XF86AUDIONEXT": "Next",
      "XF86AUDIOPREV": "Prev",
      "XF86AUDIOSTOP": "Stop",
      "XF86AUDIOMEDIA": "Media",
      "XF86AUDIOPLAYPAUSE": "Play/Pause",
      "XF86AudioRaiseVolume": "Vol Up",
      "XF86AudioLowerVolume": "Vol Down",
      "XF86AudioMute": "Mute",
      "XF86AudioMicMute": "Mic Mute",
      "XF86AudioPlay": "Play",
      "XF86AudioPause": "Pause",
      "XF86AudioNext": "Next",
      "XF86AudioPrev": "Prev",
      "XF86AudioStop": "Stop",
      "XF86AudioMedia": "Media",
      "XF86MONBRIGHTNESSUP": "Bright Up",
      "XF86MONBRIGHTNESSDOWN": "Bright Down",
      "XF86MonBrightnessUp": "Bright Up",
      "XF86MonBrightnessDown": "Bright Down",
      "XF86CALCULATOR": "Calc",
      "XF86MAIL": "Mail",
      "XF86SEARCH": "Search",
      "XF86EXPLORER": "Files",
      "XF86WWW": "Browser",
      "XF86HOMEPAGE": "Home",
      "XF86FAVORITES": "Favorites",
      "XF86POWEROFF": "Power",
      "XF86SLEEP": "Sleep",
      "XF86EJECT": "Eject",
      "XF86LOCK": "Lock",
      "XF86RFKILL": "Airplane Mode",
      "XF86Calculator": "Calc",
      "XF86Mail": "Mail",
      "XF86Search": "Search",
      "XF86Explorer": "Files",
      "XF86Www": "Browser",
      "XF86Homepage": "Home",
      "XF86Favorites": "Favorites",
      "XF86Poweroff": "Power",
      "XF86Sleep": "Sleep",
      "XF86Eject": "Eject",
      "XF86Lock": "Lock",
      "XF86Rfkill": "Airplane Mode",
      "PRINT": "PrtSc",
      "Print": "PrtSc",
      "PRIOR": "PgUp",
      "NEXT": "PgDn",
      "Prior": "PgUp",
      "Next": "PgDn",
      "MOUSE_DOWN": "Scroll Down",
      "MOUSE_UP": "Scroll Up",
      "MOUSE:272": "Left Click",
      "MOUSE:273": "Right Click",
      "MOUSE:274": "Middle Click",
      "mouse_up": "Scroll Up",
      "mouse:272": "Left Click",
      "mouse:273": "Right Click",
      "mouse:274": "Middle Click",
      "CODE:10": "1",
      "CODE:11": "2",
      "CODE:12": "3",
      "CODE:13": "4",
      "CODE:14": "5",
      "CODE:15": "6",
      "CODE:16": "7",
      "CODE:17": "8",
      "CODE:18": "9",
      "CODE:19": "0",
      "code:10": "1",
      "code:11": "2",
      "code:12": "3",
      "code:13": "4",
      "code:14": "5",
      "code:15": "6",
      "code:16": "7",
      "code:17": "8",
      "code:18": "9",
      "code:19": "0",
    };
    return keyMap[key] || key;
  }

  function saveToDb(data) {
    if (pluginApi) {
      var compositor = getCurrentCompositor();
      pluginApi.pluginSettings.cheatsheetData = data;
      pluginApi.pluginSettings.detectedCompositor = compositor;
      pluginApi.saveSettings();
    }
  }

  IpcHandler {
    target: "plugin:keybind-cheatsheet"

    function toggle() {
      if (root.pluginApi) {
        root.pluginApi.withCurrentScreen(screen => {
          root.pluginApi.togglePanel(screen);
        });
      }
    }
  }
}

