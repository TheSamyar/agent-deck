import { cursorWorkspace, safeBundleId } from './logic.mjs';

export const CURSOR_BUNDLE = 'com.todesktop.230313mzl4w4u92';
export function hostFor(session) {
  return session.agentId === 'cursor' ? CURSOR_BUNDLE : safeBundleId(session.bundleId);
}
export function matchWorkspace(titles, workspace) {
  const matches = titles.filter(title => cursorWorkspace(title).toLowerCase() === String(workspace).toLowerCase());
  if (matches.length !== 1) throw new Error(matches.length ? `Multiple windows match ${workspace}` : `No open window matches ${workspace}`);
  return matches[0];
}
export function layoutSignature(tiles) {
  return JSON.stringify(tiles.map(({key, action, target, enabled}) => [key, action, target, enabled]));
}
export function serialQueue() {
  let tail = Promise.resolve();
  return task => {
    const result = tail.then(task);
    tail = result.catch(() => {});
    return result;
  };
}
export function windowMenuScript() {
  return `tell application "System Events"
    tell process "Cursor"
      set menuItems to name of every menu item of menu "Window" of menu bar 1
      set windowNames to {}
      repeat with i from (count of menuItems) to 1 by -1
        set titleText to item i of menuItems
        if titleText is missing value then exit repeat
        set beginning of windowNames to titleText
      end repeat
      set AppleScript's text item delimiters to linefeed
      return windowNames as text
    end tell
  end tell`;
}
export function focusCursorScript() {
  return `on run argv
    set wanted to item 1 of argv
    tell application "Cursor" to activate
    tell application "System Events"
      tell process "Cursor"
        set frontmost to true
        click menu item wanted of menu "Window" of menu bar 1
        repeat 20 times
          if exists window 1 then
            set currentTitle to name of window 1
            if currentTitle is wanted then return currentTitle
          end if
          delay 0.1
        end repeat
        error "The requested Cursor window did not become active"
      end tell
    end tell
  end run`;
}
export function terminalScript(bundle, tty, terminalId, sendKey = '') {
  // Target native terminal sessions through their scripting identity, never a frontmost tab guess.
  const key = {return:'key code 36', escape:'key code 53', y:'keystroke "y"', interrupt:'keystroke "c" using control down'}[sendKey] || '';
  const find = bundle === 'com.apple.Terminal' ? `
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is wanted then
            set selected tab of w to t
            set index of w to 1
            activate
            set foundTarget to true
            set matchCount to matchCount + 1
          end if
        end repeat
      end repeat
      if foundTarget and tty of selected tab of front window is not wanted then error "Terminal selection changed"
    end tell` : `
    tell application "iTerm2"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if (wantedId is not "" and unique id of s is wantedId) or (wanted is not "" and tty of s is wanted) then
              select s
              select t
              select w
              activate
              set foundTarget to true
            set matchCount to matchCount + 1
            end if
          end repeat
        end repeat
      end repeat
      if foundTarget then
        if wantedId is not "" then
          if unique id of current session of current window is not wantedId then error "iTerm selection changed"
        else
          if tty of current session of current window is not wanted then error "iTerm selection changed"
        end if
      end if
    end tell`;
  return `on run argv
    set wanted to item 1 of argv
    set wantedId to item 2 of argv
    set foundTarget to false
    set matchCount to 0
    ${find}
    if not foundTarget then error "The agent terminal is no longer open"
    if matchCount is not 1 then error "More than one terminal matches this agent"
    ${key ? `tell application "System Events"\nrepeat 20 times\nif (bundle identifier of (first application process whose frontmost is true)) is "${bundle}" then exit repeat\ndelay 0.1\nend repeat\nif (bundle identifier of (first application process whose frontmost is true)) is not "${bundle}" then error "Terminal app did not become active"\n${key}\nend tell` : ''}
    return "focused"
  end run`;
}

export function focusWindowScript(bundle) {
  if (!safeBundleId(bundle)) throw new Error('Invalid application bundle');
  return `on run argv
    set wanted to item 1 of argv
    tell application "System Events"
      set hostProcess to first application process whose bundle identifier is "${bundle}"
      tell hostProcess
        set candidates to {}
        repeat with w in windows
          if name of w as text is wanted then set end of candidates to w
        end repeat
        if count of candidates is not 1 then error "The project window is missing or ambiguous"
        set frontmost to true
        perform action "AXRaise" of item 1 of candidates
        if name of window 1 as text is not wanted then error "The project window did not become active"
        return wanted
      end tell
    end tell
  end run`;
}
