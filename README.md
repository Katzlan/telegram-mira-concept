# AI Assistant in Group Chats

Group chats already have AI bots, but calling one feels like a workaround: you have to remember its username,
it gets lost among the members, and anything you ask it lands in front of the whole group.
This concept makes an assistant (here **@mira**) a first-class part of a group:

* **@ button** next to the attachment button starts a mention. AI assistants come first in the list, with an **AI** badge.
* **Ask in the chat.** `@mira what did we agree on last Thursday?` gets an answer as a reply, and everyone sees it.
* **Assistant button** in the group header opens a **side panel**: a private thread with the assistant, scoped to this group (🔒 *Internal Team*). The group slides aside and stays visible on the left.
* **Drag to share.** Long-press anything the assistant sends in the panel (e.g. a sticker) and drop it onto the group to post it there.
* The assistant's avatar in the panel opens its mini app. The panel has a search over the thread.

Telegram concept for **iOS** (UIKit / AsyncDisplayKit, SwiftUI for the panel), built on top of the official sources.

| Demo |
|---|

https://github.com/user-attachments/assets/0b45acf6-68f7-4e83-9e1a-f59fe652f079

## Repository

| Path | What |
|---|---|
| `ios/Feature/submodules/…` | New files, at the same paths as in Telegram-iOS: copy the folder over a checkout. |
| `ios/Integration/telegram-ios.patch` | Hooks in existing Telegram-iOS files (`git apply`). |
| `Media/` | The recording of the concept (1920×1920, 60 fps). |

## iOS

| File | What |
|---|---|
| `TelegramUI/Sources/MiraAssistant.swift` | Which bots are assistants (by username), resolving them, the AI badge, the header button, opening the panel. |
| `TelegramUI/Sources/MiraSidePanel.swift` | The side panel: group slide-out, the private per-group thread, composer handover, search, sticker drag & drop. |
| `TelegramUI/Sources/MiraDemo.swift` | Offline demo used for the recording (see below). Not part of the feature. |

Hooks in existing files (see the patch):

* `ChatTextInputPanelNode` — the **@** button.
* `ChatInterfaceStateContextQueries`, `MentionChatInputPanelItem` — assistants first in the mention list, the AI badge and subtitle; `@mira …` is not treated as an inline-bot query.
* `ChatNavigationButton`, `ChatInterfaceStateNavigationButtons`, `UpdateChatPresentationInterfaceState`, `ChatControllerNavigationButtonAction`, `ChatControllerSideColumn`, `ChatController` — the assistant button in the header; the group ignores the keyboard while the panel is open.
* `ExperimentalUISettings`, `DebugController` — the switch.
* `ApplicationContext`, `ChatControllerLoadDisplayNode`, `ChatControllerOpenMessageContextMenu`, `ChatMessageItemCommon` — demo mode only (local chats, scripted typing, likes on local messages).
* `Display/WindowContent` — one `#if compiler(>=6.4)` guard so the base commit builds with Xcode 26.

Base commit: `d687db62f3ae6a23ebf11f9db255791d036b5ecd` (TelegramMessenger/Telegram-iOS).

```sh
cd Telegram-iOS
git checkout d687db62f3ae6a23ebf11f9db255791d036b5ecd
cp -R /path/to/this-repo/ios/Feature/submodules/ submodules/
git apply /path/to/this-repo/ios/Integration/telegram-ios.patch
```

Build as usual (`build-system/Make/Make.py` or the generated Xcode project). Everything is behind
**Debug → "AI assistants in groups"** (`ExperimentalUISettings.miraAssistant`). The side panel needs iOS 17;
on older systems the assistant button opens the bot's chat.

### Demo mode

Launch with the argument `--mira-demo` to get the offline scenario from the video: a fictional group
(Sophie, Lukas, Elena, Marco) and a fictional Mira, stored only on the device. The group's members write on
a script, and nothing in the demo chats is sent to Telegram's servers. Real in-app notifications are muted for the run.

## Notes and limits

* **Real:** the mention list, the @ button, the header button, the side panel and its search, opening the mini app, and posting a dragged sticker to the group (outside the demo it is a real message).
* **Mocked:** the assistant's answers in the side panel are scripted on the device (thinking, streaming text, a sticker). This is where the bot's API would plug in. A real implementation would also need a server-side flag for assistant bots; here they are listed by username.
* The answer in the group in the video comes from the demo script, not from the real @mira bot.
* @mira is used as an example of an AI bot that works in groups; the concept is not affiliated with it.
* Demo avatars and photos are demo images.
* Telegram sources are GPLv2; these files are meant to be used on top of them.
