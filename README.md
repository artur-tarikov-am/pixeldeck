<p align="center">
  <img src="mac/PixeldeckMac/Assets.xcassets/AppIcon.appiconset/icon-256.png" width="112" alt="">
</p>

<h1 align="center">Pixeldeck</h1>

<p align="center">
  A pixel status board in the notch of the Mac.<br>
  It counts what Claude Code and other agents are doing, follows your pull requests and reminds you of meetings.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-111111?logo=apple&logoColor=white" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Claude_Code-plugin-D97757?logo=claude&logoColor=white" alt="Claude Code plugin">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3DA639" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/images/hero.gif" width="800" alt="The open notch: tiles for Orca chats, GitHub pull requests and the next meeting, and two cards sent by scripts">
</p>

Scripts and agents send it things to show, and it opens when the pointer rests on the notch.

    scripts, hooks ──HTTP──┐
                           ├─► hub ◄── stream + clicks ──► notch
    Claude, agents ───MCP──┘

One app runs the hub and the notch. The hub is `mac/HubKit`; it listens on `127.0.0.1:7777`, so only this Mac reaches it. `mac/PixeldeckMac` is the app around it, and `mac/PixeldeckMac/Board` draws the board.

<p align="center">
  <img src="docs/images/closed.gif" width="600" alt="The closed notch with the character on the left wing and counts of agents and a meeting on the right, then two lines of news under it">
</p>

Closed, the notch grows wings while something is going on. The character sits on the left, the agents at work and the next meeting on the right. When an agent finishes or a pull request gets approved, a line drops under the notch for three seconds.

<table>
  <tr>
    <td width="50%" valign="top"><img src="docs/images/orca.png" alt="List of Orca chats"></td>
    <td width="50%" valign="top"><img src="docs/images/github.png" alt="List of pull requests"></td>
  </tr>
  <tr>
    <td align="center">Orca chats, waiting ones first. A click opens the chat in Orca.</td>
    <td align="center">Your pull requests and the ones waiting for your review</td>
  </tr>
  <tr>
    <td valign="top"><img src="docs/images/meetings.png" alt="Today's meetings"></td>
    <td valign="top"><img src="docs/images/catalog.png" alt="Catalog of integrations"></td>
  </tr>
  <tr>
    <td align="center">Today's meetings. A click joins the call.</td>
    <td align="center">Integrations. A click switches one on or off.</td>
  </tr>
</table>

## Running

    mac/install.sh                 # builds the app, puts it into /Applications and starts it
    mac/package.sh                 # builds it for Apple silicon and Intel into mac/build/Pixeldeck.zip

The app has no icon in the menu bar: its menu opens with a right click on the notch. It shows whether the hub runs, and has Settings and Quit. Settings switch the integrations on and off, let the notch read the calendar, connect Claude Code, start and stop the hub, open its log and set Launch at Login (`SettingsView.swift`). Quitting stops the hub and the notch; Claude keeps working.

The app has no sandbox, because it runs `gh` and `claude`. An app started from Finder gets a short PATH, so once per launch it asks the login shell of the user for the PATH that Terminal has. It is signed with the Apple Development certificate. The hub listens only on loopback, so the macOS firewall does not ask about it.

Tests: `cd mac/HubKit && swift test`.

### On another Mac

`mac/package.sh` makes a zip to send; the app needs macOS 15 or later. Nothing in it is tied to this Mac: the data lives in `~/.pixeldeck` of whoever runs it, and Orca and `gh` are looked up in their home.

1. Unzip, move `Pixeldeck.app` into Applications and open it. The app is not notarized, so macOS refuses the first launch: System Settings → Privacy & Security → Open Anyway. Notarizing needs a paid Apple developer account.
2. Right-click the notch, choose Settings and click Connect next to the Pixeldeck plugin. It needs `claude` in Terminal; Claude sessions started afterwards show on the board.
3. For the GITHUB tile, `gh auth login` in Terminal.

## Board

The screen is made of tiles and a feed. The feed at the bottom holds only cards sent by scripts and agents.

The cat beside the notch shows the connection to the hub. Orange and awake means the hub answers. Grey means no connection: it sleeps while offline and looks around while connecting.

**ORCA.** Every 3 seconds the hub asks Orca for its chats and agent terminals, whichever provider runs them, and the tile counts them by state: a coloured dot and a number each for waiting, running, failed and done. A waiting chat turns the tile's border yellow. Click the tile for the list of all of them by name, waiting ones first, with the provider and the project under the name (`claude · Pixeldeck`). Click a row to open that chat in Orca, swipe right or click `< ORCA` beside the notch to go back, pull the list down to ask Orca right away. The board sends only the key, so it cannot open anything Orca did not report. Swipe a row left to uncover the close button, as in Messages. A long swipe closes a finished chat right away; a chat with a working or waiting agent only closes by a click on the button, because that stops the agent. Scheduled runs (`tg-digest run 3438`) are hidden unless they wait for you. Tabs pinned in Orca go to the top of the list with a pin in the corner. Orca does not report what a chat asks, so an `AskUserQuestion` question comes from the Claude hooks and only Claude chats show one under their row. The hub talks to the socket the `orca` command uses (`OrcaRuntime.swift`); this API is internal to Orca and may change with an update, so a failure ends up in `hub.log`. The socket does not report pins, so the hub reads them from `profile-state.db`, read-only and only when its revision changes (`OrcaPins.swift`), which puts them up to 5 seconds behind the window. If that fails the last known pins stay and the chats are not affected.

**CLAUDE.** Claude Code reports through the plugin in `mac/ClaudePlugin`: its hook `claude-hook.sh` posts each event to `POST /claude-events` without the prompt or tool output, and its `.mcp.json` gives Claude the tools from MCP below. Claude Code reads a plugin from its folder in place, so the app copies its own to `~/.pixeldeck/claude-plugin` at every launch: the hooks survive moving or deleting the app and follow its updates. Connect in Settings runs `claude plugin install pixeldeck --marketplace ~/.pixeldeck/claude-plugin`; for another config folder run the same in Terminal with `CLAUDE_CONFIG_DIR` set. The tile counts the Claude Code sessions outside Orca and stays hidden while there are none. Finished sessions stay for two minutes. Click the tile for the list and swipe right or click `< CLAUDE` to go back; these sessions cannot be opened or closed from the board. While Orca is switched off or does not answer, the sessions inside it show here too, so the board keeps counting them. The logic is in `mac/HubKit/Sources/HubKit/ClaudeActivity.swift`.

The character sits on the top agent tile, ORCA or else CLAUDE, and reacts to both: to every session outside Orca and to the chats in Orca that are at work or finished within the last two minutes. Its text from `set_status` sits there too.

**GITHUB.** Once a minute the hub asks `gh` for your open pull requests and review requests, skipping drafts. The logic is in `mac/HubKit/Sources/HubKit/Github.swift`. The tile has a line each for your pull requests and for review requests, with a coloured dot and a number per state. The octopus beside them acts out the most urgent light: it blows bubbles while CI runs, waves when changes are requested, goes red when CI fails, reads a page when your review is requested, and is pleased with an approved pull request. Click the tile for the list, click a row to open the pull request in the browser. The board sends only the key, so it cannot make the Mac open anything GitHub did not report. Swipe right or click `< GITHUB` beside the notch to go back to the board. Pull down on the board or the list to ask GitHub right away. The cross switches a light off until the checks, the review decision or the title change; muted items are kept in `~/.pixeldeck/github-muted.json`.

| Light | Agent | My pull request | Meeting |
| --- | --- | --- | --- |
| orange, breathing | working | CI running | under way |
| yellow, blinking | waiting for you | changes requested | time to join: from 2 minutes before the start to 5 minutes into it |
| green | finished | approved, CI green | |
| red | failed | CI failed | |
| grey | | awaiting review | later today |
| blue | | your review is requested | within 10 minutes |

**MEETINGS.** The app reads the calendar itself, so the hub never gets the meetings. Once a minute it asks the Calendar app of this Mac for today's events, so a Google, iCloud or Exchange calendar has to be added there in System Settings → Internet Accounts. It needs access once: Settings → Calendar → Allow, and the same section says how many meetings are left today, so an account missing from the Calendar shows there. A meeting is an event that is not all-day, not cancelled and not declined, with you among its guests, or an event of your own with a call link. Events with guests but without you, such as those of a colleague whose calendar is shared with you, do not count, and neither do birthdays and subscribed calendars. The tile shows the meeting to join, else the one within ten minutes, else the one under way, else the next one today, and how many more are left; it hides once the day has none. Click it for the list, click a row to open the call in the browser. The link is the first Google Meet, Zoom or Teams address in the URL, the location or the notes of the event; a row without one says `no link` and does nothing. The code is in `mac/PixeldeckMac/MeetingCalendar.swift`, the phases in `mac/PixeldeckMac/Board/Meeting.swift`.

**INTEGRATIONS.** Swipe right on the board for the catalog, swipe left to come back. Click an integration to switch it on or off, or use the switches in Settings. The hub keeps the choice in `state.json`, so it survives restarts. A new board starts with what the Mac has: ORCA if Orca has run there, GITHUB if `gh` has a login, CLAUDE always. A switched-off integration loses its tile: GitHub stops asking `gh`, Orca stops being asked, Claude keeps following sessions and shows them again when switched back on. The character and `set_status` go with the last agent tile; cards stay in the feed. With everything off, no cards and no meetings left today the board goes to the character, who has nothing to do: the skits are in `EmptyBoard.swift`. A new integration is an entry in `Integration.catalog` in `Schema.swift`, a tile in `Board/Scene.swift` and a name for Settings in `SettingsView.swift`.

## Notch

The app shows the board in the notch of the MacBook, or under a notch-sized spot in the middle of the menu bar on a screen without one. The notch reads the hub of the same app over `127.0.0.1:7777`, so a stopped or failed hub puts it to sleep.

Closed, the notch grows wings only while there is something to see. The character on the left wing is the one from the top agent tile, with the same mood; the right wing has a light and a number for the agents that are running, waiting or failed, and after a line the next meeting within ten minutes: `7m`, then `now` when it is time to join. Finished agents only make the character happy. While the hub is away both sleep, and the grey critter takes the right wing; the meeting stays, since the calendar does not go through the hub. With nothing going on the notch stays as it is.

When something happens, the closed notch drops a line under itself for three seconds, so it is not missed while nobody looks at the wings: a new card with its title, an agent that finished, failed or waits for you (`Pixeldeck finished`), a pull request of yours that got approved, failed CI or got changes requested (`#412 Fix the build approved`), a meeting five minutes before it and as it starts (`Billing sync in 5m`, `Billing sync starts now`). A reminder missed by more than a minute, while the notch was open, is not told late. The name is cut short first, so the change always shows. Only rows the notch has already seen count, so a hub that starts or an integration switched on stays silent. Several pieces of news follow one another; a newer one about the same row replaces the one still waiting. Nothing queues while the notch is open, since the board shows it all.

Rest the pointer on the notch and it opens into the board with its tiles, lists, catalog and cards, the clock and the critter beside the camera, its height following the content up to 60% of the screen. It closes once the pointer leaves. A mouse drag and two fingers on the trackpad do the same things: scroll, pull down to refresh, swipe right to the catalog or back from a list, swipe a chat left for its close button. A mouse wheel only scrolls. Links on cards open in the browser. Right-click for the menu.

The panel lies over the menu bar, never takes focus from the app in front, and lets clicks through everywhere outside the black shape. The code is in `mac/PixeldeckMac/Notch`: `NotchController.swift` follows the pointer, `NotchView.swift` draws the shape, `NotchBar.swift` the wings and the line of news, `NotchNews.swift` tells what happened from two decks in a row, `TrackpadDrags.swift` turns trackpad scrolling into drags. The closed notch stays on screen all day, so `WingsView.swift` draws it into a layer on its own clock: through SwiftUI twelve frames a second cost several percent of the CPU, this way it is about one.

## Cards

The hub takes requests only from this Mac and refuses those from browsers.

    curl 127.0.0.1:7777/cards -d '{
      "key": "pr-40405",
      "title": "PR #40405 needs review",
      "text": "CI is green",
      "sprite": "waiting",
      "actions": [
        {"label": "Open", "url": "https://github.com/..."},
        {"label": "Merge", "run": "merge-pr", "args": ["40405"]}
      ]
    }'

- `key` is optional: a card with the same key replaces the previous one.
- `sprite` sets the picture and the border color: `idle`, `walk`, `thinking`, `waiting`, `done`, `error`, `alert`, `sleep`. You can send your own, up to 32×32: `{"palette": {"a": "#ff0000"}, "frames": [["a.a", ".a."]], "fps": 4}`.
- A card has up to four actions, each with one of: `url` opens in the browser, `run` starts an action from the config, `reply` answers whoever is waiting and removes the card.

| Request | What it does |
| --- | --- |
| `POST /cards` | create or replace a card |
| `GET /cards` | list cards |
| `DELETE /cards/:id` | remove a card |
| `GET /cards/:id/answer?timeout=60` | wait for a `reply` |
| `PUT /status` | set the character's mood: `{"mood": "thinking", "text": "...", "ttlSeconds": 1800}` |
| `PUT /integrations/:id` | switch `orca`, `claude` or `github`: `{"isOn": false}` |

Moods: `idle`, `thinking`, `waiting`, `done`, `error`. Anything except `idle` resets by itself after `ttlSeconds`.

## Actions on the Mac

A card refers to an action by name; the commands live in `~/.pixeldeck/actions.json`, so a card cannot run arbitrary commands on the Mac. The file is reread on every press, no restart needed.

    {
      "merge-pr": { "command": ["gh", "pr", "merge", "--squash"], "timeoutSeconds": 120 }
    }

`args` from the card are appended to the command as separate arguments, without a shell.

## MCP

Claude Code gets the server with the plugin. Another client takes it by hand:

    claude mcp add --transport http pixeldeck http://127.0.0.1:7777/mcp

Tools: `show_card`, `set_status`, `ask` (a question on the board that waits for a click), `remove_card`, `list_cards`.

## How the board is drawn

Frames are drawn into small buffers and scaled up without smoothing. On a Retina screen the board uses 4 physical pixels per cell, the feed, the pull request list and the row beside the notch use 3. That row holds the clock on the board and the way back on the lists. The board redraws 12 times a second; the feed is a separate layer that follows the display rate while it moves.

The code is in `mac/PixeldeckMac/Board`: `Scene.swift` draws the tiles and keeps the click zones, `CardFeed.swift` draws the feed and the list, `Light.swift` draws the lights, `DeckModel.swift` holds the connection, `DeckGestures.swift` turns drags and clicks into scrolling, swipes and presses, `FrameView.swift` stacks the layers of a frame. The characters are generated by `tools/make_sprites.py`, the font (X11 6×10, public domain) is baked by `tools/bake_font.py`, the icon by `tools/make_icon.py`.

## License

MIT, see [LICENSE](LICENSE).
