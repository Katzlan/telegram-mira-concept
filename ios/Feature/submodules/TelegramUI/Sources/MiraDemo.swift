import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatMessageItemCommon

/// Demo mode for recording the concept: fictional people and group chats, stored only in this device's database.
///
/// Launch the app with `--mira-demo`. The account stays the real one ("You"), everything else is made up:
/// Sophie, Lukas, Elena and Marco, the groups "Internal Team" and "Liveness & Co", and Mira herself. The demo chats
/// never reach Telegram's servers: what you send there, your reactions and the sticker dragged out of Mira's panel
/// are written locally, and the other people answer from the script below. Real in-app notifications are muted for
/// the run, so nothing private pops up in a recording.
///
/// This file is the test bench, not the feature: the feature (MiraAssistant, MiraSidePanel and the hooks) works
/// with the real @mira bot in real groups, and only asks `MiraDemo` whether a chat is a demo one.
final class MiraDemo {
    static let isRequested: Bool = ProcessInfo.processInfo.arguments.contains("--mira-demo") || startsInGroup
    /// `--mira-demo-group` is kept as an alias of `--mira-demo`.
    static let startsInGroup: Bool = ProcessInfo.processInfo.arguments.contains("--mira-demo-group")

    private(set) static var shared: MiraDemo?

    // MARK: - Cast

    struct Person {
        let id: EnginePeer.Id
        let firstName: String
        let lastName: String?
        let username: String
        let avatar: String?
        let isBot: Bool
    }

    private static func userId(_ value: Int64) -> EnginePeer.Id {
        // Far above real ids, so they can never collide with a server peer.
        return EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(9_000_000_000_000 + value))
    }

    private static func groupId(_ value: Int64) -> EnginePeer.Id {
        return EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(900_000_000 + value))
    }

    static let mira = Person(id: userId(1), firstName: "Mira", lastName: nil, username: "mira", avatar: "Avatar/DemoMira", isBot: true)
    static let sophie = Person(id: userId(10), firstName: "Sophie", lastName: "Martin", username: "sophie_m", avatar: "Avatar/DemoSophie", isBot: false)
    static let lukas = Person(id: userId(11), firstName: "Lukas", lastName: "Weber", username: "lukas", avatar: "Avatar/DemoLukas", isBot: false)
    static let elena = Person(id: userId(12), firstName: "Elena", lastName: "Novak", username: "elena", avatar: "Avatar/DemoElena", isBot: false)
    static let marco = Person(id: userId(13), firstName: "Marco", lastName: "Rossi", username: "marco", avatar: nil, isBot: false)

    static let people: [Person] = [mira, sophie, lukas, elena, marco]
    /// Mention list order after Mira (who the feature puts first anyway).
    static let members: [Person] = [marco, lukas, sophie, elena]

    static let internalTeamId = groupId(1)
    static let livenessId = groupId(2)

    static func isDemoChat(_ peerId: EnginePeer.Id?) -> Bool {
        guard self.isRequested, let peerId else {
            return false
        }
        return peerId == self.internalTeamId || peerId == self.livenessId
    }

    private static func telegramUser(_ person: Person) -> TelegramUser {
        var photo: [TelegramMediaImageRepresentation] = []
        if person.avatar != nil {
            photo.append(TelegramMediaImageRepresentation(
                dimensions: PixelDimensions(width: 640, height: 640),
                resource: self.avatarResource(person),
                progressiveSizes: [],
                immediateThumbnailData: nil
            ))
        }
        return TelegramUser(
            id: person.id,
            // Avatars are only drawn for peers with an access hash; the photo itself is already in the media box.
            accessHash: .personal(1),
            firstName: person.firstName,
            lastName: person.lastName,
            username: person.username,
            phone: nil,
            photo: photo,
            botInfo: person.isBot ? BotUserInfo(flags: [.worksWithGroups, .hasAccessToChatHistory], inlinePlaceholder: nil) : nil,
            restrictionInfo: nil,
            flags: [],
            emojiStatus: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            subscriberCount: nil,
            verificationIconFileId: nil
        )
    }

    private static func avatarResource(_ person: Person) -> LocalFileMediaResource {
        return LocalFileMediaResource(fileId: 9_000_000_000_000 + person.id.id._internalGetInt64Value())
    }

    static var miraPeer: EnginePeer {
        return EnginePeer.user(self.telegramUser(self.mira))
    }

    private static func group(id: EnginePeer.Id, title: String, count: Int) -> TelegramGroup {
        return TelegramGroup(id: id, title: title, photo: [], participantCount: count, role: .member, membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 0)
    }

    /// The people offered in the demo group's mention list (Mira is added by the feature).
    static func memberPeers(matching query: String) -> Signal<[EnginePeer], NoError> {
        let query = query.lowercased()
        let peers = self.members
            .filter { query.isEmpty || $0.username.hasPrefix(query) || $0.firstName.lowercased().hasPrefix(query) || ($0.lastName?.lowercased().hasPrefix(query) ?? false) }
            .map { EnginePeer.user(self.telegramUser($0)) }
        return .single(peers)
    }

    // MARK: - Script

    private enum Script {
        static let sophieQuestion = "Folks, can someone remind me what we decided with the Liveness developers? Are we handing our camera concept over to them? ASAP"
        static let lukasReply = "Same question"
        static let miraThinking = "Thinking about Thursday's chat…"
        static let miraAnswer = "Last Thursday, together with Marco Rossi and the Liveness team, you already handed over the concepts for the Liveness camera update. Tomorrow the Liveness team will prepare the update."
        static let sophieReply = "Great job! How do you all find the time for everything?"
        static let elenaReply = "Ooh, super!"
        static let marcoReply = "Yeah!!"
        /// (emoji, who, pause before it)
        static let answerReactions: [(String, Person, Double)] = [
            ("\u{2764}", sophie, 0.8), ("🔥", lukas, 0.5), ("\u{2764}", elena, 0.5), ("🤝", marco, 0.5), ("🔥", sophie, 0.4), ("\u{2764}", lukas, 0.4), ("🤝", elena, 0.5)
        ]
        static let stickerReactions: [(String, Person, Double)] = [
            ("🎉", sophie, 0.9), ("\u{2764}", elena, 0.5), ("🎉", lukas, 0.4), ("🎉", marco, 0.4), ("\u{2764}", sophie, 0.5), ("🎉", elena, 0.4)
        ]
        /// Seconds after the start chat appears before Sophie's question arrives.
        static let questionDelay: Double = 3.0
    }

    // MARK: - State

    private let context: AccountContext
    private let startDate = Date()
    /// Demo clock: today 13:02 (the simulator status bar is set to it) plus the time since launch.
    private let anchor: Date

    private var visibleChatId: EnginePeer.Id?
    private var sophieAsked = false
    private var lukasReplied = false
    private var miraAnswerId: MessageId?
    private var celebrated = false

    private struct ReactionState {
        var counts: [(emoji: String, peers: [EnginePeer.Id])] = []
        var mine: String?
    }
    private var reactions: [MessageId: ReactionState] = [:]

    private let typing = ValuePromise<[EnginePeer.Id: EnginePeer.Id]>([:], ignoreRepeated: true)
    private var typingValue: [EnginePeer.Id: EnginePeer.Id] = [:]
    private let notificationsPipe = ValuePipe<[([Message], PeerGroupId, Bool, MessageHistoryThreadData?)]>()

    private init(context: AccountContext) {
        self.context = context
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 13
        components.minute = 2
        self.anchor = Calendar.current.date(from: components) ?? Date()
    }

    private func now() -> Int32 {
        return Int32(self.anchor.timeIntervalSince1970 + Date().timeIntervalSince(self.startDate))
    }

    private func yesterday(_ hour: Int, _ minute: Int) -> Int32 {
        return Int32(self.anchor.timeIntervalSince1970) - 24 * 60 * 60 + Int32((hour - 13) * 3600 + (minute - 2) * 60)
    }

    private func today(_ hour: Int, _ minute: Int) -> Int32 {
        return Int32(self.anchor.timeIntervalSince1970) + Int32((hour - 13) * 3600 + (minute - 2) * 60)
    }

    // MARK: - Hooks used by the app

    /// In-app notifications during the demo: only the script's, never the account's real ones.
    static func notificationSource(real: Signal<[([Message], PeerGroupId, Bool, MessageHistoryThreadData?)], NoError>) -> Signal<[([Message], PeerGroupId, Bool, MessageHistoryThreadData?)], NoError> {
        guard self.isRequested else {
            return real
        }
        return Signal { subscriber in
            let disposable = MetaDisposable()
            let start: () -> Void = {
                if let shared = MiraDemo.shared {
                    disposable.set(shared.notificationsPipe.signal().start(next: { value in
                        subscriber.putNext(value)
                    }))
                }
            }
            Queue.mainQueue().async(start)
            return disposable
        }
    }

    static func typingActivities(peerId: EnginePeer.Id) -> Signal<[(EnginePeer.Id, PeerInputActivity)], NoError> {
        guard self.isDemoChat(peerId), let shared = self.shared else {
            return .single([])
        }
        return shared.typing.get()
        |> map { typing -> [(EnginePeer.Id, PeerInputActivity)] in
            if let author = typing[peerId] {
                return [(author, .typingText)]
            }
            return []
        }
    }

    /// Seeds the demo chats (wiping any previous run), then opens the start chat.
    static func start(context: AccountContext, openChat: @escaping (EnginePeer.Id) -> Void) {
        guard self.isRequested, self.shared == nil else {
            return
        }
        let demo = MiraDemo(context: context)
        self.shared = demo
        // Reaction icons are downloaded on first use; fetch the script's ones now so no chip shows up empty.
        let scriptReactions: Set<String> = ["\u{2764}", "🔥", "🤝", "👍", "🙏", "💯", "🎉"]
        let _ = (context.engine.stickers.availableReactions() |> take(1)).start(next: { value in
            for reaction in value?.reactions ?? [] {
                guard case let .builtin(emoji) = reaction.value, scriptReactions.contains(emoji) else { continue }
                for file in [reaction.staticIcon._parse(), reaction.centerAnimation?._parse()].compactMap({ $0 }) {
                    let _ = freeMediaFileInteractiveFetched(account: context.account, userLocation: .other, fileReference: .standalone(media: file)).start()
                }
            }
        })
        // Double tap likes a message in the demo chats, although their messages are local.
        localMessageReactionsAllowed = { MiraDemo.isDemoChat($0.peerId) }
        let _ = (demo.seed()
        |> then(demo.seedYesterdayStickers())
        |> deliverOnMainQueue).start(completed: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // The demo opens in Internal Team; Sophie's question arrives a few seconds later.
                openChat(MiraDemo.internalTeamId)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Script.questionDelay * 1_000_000_000))
                    await demo.sophieAsks(notify: false)
                }
            }
        })
    }

    /// On a normal launch the demo groups stay out of the chat list.
    static func hideFromChatList(context: AccountContext) {
        let _ = context.account.postbox.transaction({ transaction -> Void in
            for peerId in [MiraDemo.internalTeamId, MiraDemo.livenessId] where transaction.getPeer(peerId) != nil {
                transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
            }
        }).start()
    }

    func chatDidAppear(peerId: EnginePeer.Id) {
        self.visibleChatId = peerId
        guard peerId == MiraDemo.internalTeamId, self.sophieAsked, !self.lukasReplied else {
            return
        }
        self.lukasReplied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self.reply(from: MiraDemo.lukas, text: Script.lukasReply, typing: 0.7)
        }
    }

    /// The user sent something in a demo chat: store it as sent and read, and let Mira answer an @mira question.
    func userSent(_ messages: [EnqueueMessage], peerId: EnginePeer.Id) {
        for message in messages {
            guard case let .message(text, attributes, _, mediaReference, _, replyToMessageId, _, _, correlationId, _) = message else {
                continue
            }
            var stored: [MessageAttribute] = attributes.filter { $0 is TextEntitiesMessageAttribute }
            // The chat clears its input once it sees the message with this correlation id.
            stored.append(OutgoingMessageInfoAttribute(uniqueId: Int64.random(in: 1 ... Int64.max), flags: [], acknowledged: true, correlationId: correlationId, bubbleUpEmojiOrStickersets: [], partialReference: nil))
            if let replyToMessageId {
                stored.append(ReplyMessageAttribute(messageId: replyToMessageId.messageId, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil))
            }
            let media: [Media] = mediaReference.flatMap { [$0.media] } ?? []
            let storedAttributes = stored
            Task { @MainActor in
                let id = await self.store(peerId: peerId, author: self.context.account.peerId, incoming: false, text: text, attributes: storedAttributes, media: media, timestamp: self.now())
                if let id, peerId == MiraDemo.internalTeamId, text.range(of: "@mira", options: .caseInsensitive) != nil {
                    await self.miraAnswers(question: id)
                }
            }
        }
    }

    /// The sticker dragged out of Mira's panel lands in the group; everyone laughs.
    func sendSticker(_ file: TelegramMediaFile) {
        Task { @MainActor in
            guard let id = await self.store(peerId: MiraDemo.internalTeamId, author: self.context.account.peerId, incoming: false, text: "", attributes: [], media: [file], timestamp: self.now()) else {
                return
            }
            for (emoji, person, delay) in Script.stickerReactions {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self.addReaction(emoji, from: person.id, to: id)
            }
        }
    }

    /// The user's own reaction in a demo chat. Liking Mira's answer starts the celebration.
    func setOwnReaction(messageId: MessageId, emoji: String?) {
        // Any reaction from a double tap is a like in the demo.
        let emoji: String? = emoji == nil ? nil : "👍"
        Task { @MainActor in
            var state = self.reactions[messageId] ?? ReactionState()
            state.mine = emoji
            self.reactions[messageId] = state
            await self.writeReactions(messageId)
            if messageId == self.miraAnswerId, emoji != nil, !self.celebrated {
                self.celebrated = true
                await self.celebrate(answerId: messageId)
            }
        }
    }

    // MARK: - Scenes

    @MainActor
    private func sophieAsks(notify: Bool) async {
        guard let id = await self.store(peerId: MiraDemo.internalTeamId, author: MiraDemo.sophie.id, incoming: true, text: Script.sophieQuestion, attributes: [], media: [], timestamp: self.now()) else {
            return
        }
        self.sophieAsked = true
        // Show it as a banner, the way Telegram shows a message from another chat.
        let message: Message? = await self.value(self.context.account.postbox.transaction { transaction -> Message? in
            return transaction.getMessage(id)
        }) ?? nil
        if notify, let message {
            self.notificationsPipe.putNext([([message], .root, true, nil)])
        }
        // Already in the group: Lukas chimes in right away.
        if self.visibleChatId == MiraDemo.internalTeamId {
            self.chatDidAppear(peerId: MiraDemo.internalTeamId)
        }
    }

    @MainActor
    private func miraAnswers(question: MessageId) async {
        try? await Task.sleep(nanoseconds: 450_000_000)
        self.setTyping(MiraDemo.mira.id, in: MiraDemo.internalTeamId)
        defer { self.setTyping(nil, in: MiraDemo.internalTeamId) }

        let reply = ReplyMessageAttribute(messageId: question, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil)
        guard let id = await self.store(peerId: MiraDemo.internalTeamId, author: MiraDemo.mira.id, incoming: true, text: Script.miraThinking, attributes: [reply, MiraDemo.italic(Script.miraThinking)], media: [], timestamp: self.now()) else {
            return
        }
        self.miraAnswerId = id
        try? await Task.sleep(nanoseconds: 2_200_000_000)

        // Stream the answer a few characters at a time, like an LLM.
        let characters = Array(Script.miraAnswer)
        var index = 0
        while index < characters.count {
            index = min(index + Int.random(in: 2 ... 5), characters.count)
            await self.updateText(id, text: String(characters[0 ..< index]), extra: [reply])
            try? await Task.sleep(nanoseconds: UInt64.random(in: 30_000_000 ... 55_000_000))
        }
    }

    @MainActor
    private func celebrate(answerId: MessageId) async {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.reply(from: MiraDemo.sophie, text: Script.sophieReply, typing: 1.2)
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self.reply(from: MiraDemo.elena, text: Script.elenaReply, typing: 1.0)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self.reply(from: MiraDemo.marco, text: Script.marcoReply, typing: 0.8)
        }
        for (emoji, person, delay) in Script.answerReactions {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.addReaction(emoji, from: person.id, to: answerId)
        }
    }

    @MainActor
    private func reply(from person: Person, text: String, typing: Double) async {
        self.setTyping(person.id, in: MiraDemo.internalTeamId)
        try? await Task.sleep(nanoseconds: UInt64(typing * 1_000_000_000))
        self.setTyping(nil, in: MiraDemo.internalTeamId)
        let _ = await self.store(peerId: MiraDemo.internalTeamId, author: person.id, incoming: true, text: text, attributes: [], media: [], timestamp: self.now())
    }

    private func setTyping(_ author: EnginePeer.Id?, in chat: EnginePeer.Id) {
        if let author {
            self.typingValue[chat] = author
        } else {
            self.typingValue.removeValue(forKey: chat)
        }
        self.typing.set(self.typingValue)
    }

    // MARK: - Seeding

    private func seed() -> Signal<Void, NoError> {
        for person in MiraDemo.people {
            if let name = person.avatar, let data = UIImage(bundleImageName: name)?.jpegData(compressionQuality: 0.9) {
                self.context.account.postbox.mediaBox.storeResourceData(MiraDemo.avatarResource(person).id, data: data, synchronous: true)
            }
        }
        let accountPeerId = self.context.account.peerId
        let history: [(EnginePeer.Id, Person?, Int32, String, [(String, Int32)])] = [
            // Internal Team, yesterday.
            (MiraDemo.internalTeamId, MiraDemo.sophie, self.yesterday(11, 45), "Can we move the calls to 6 PM?", [("👍", 2), ("🙏", 1)]),
            (MiraDemo.internalTeamId, MiraDemo.lukas, self.yesterday(11, 45), "I only leave work at 5", []),
            (MiraDemo.internalTeamId, MiraDemo.marco, self.yesterday(11, 51), "+", [("👍", 1)]),
            (MiraDemo.internalTeamId, MiraDemo.elena, self.yesterday(15, 39), "hmm, I have plans at 6 though", []),
            (MiraDemo.internalTeamId, MiraDemo.lukas, self.yesterday(15, 39), "well, I am still slowly moving house", [("🤝", 1)]),
            (MiraDemo.internalTeamId, MiraDemo.marco, self.yesterday(15, 52), "We can move it to tomorrow evening if you want?", [("💯", 2), ("🔥", 1)]),
            // Liveness & Co, the chat the demo starts in.
            (MiraDemo.livenessId, MiraDemo.marco, self.yesterday(17, 10), "Uploaded the new onboarding screens to Figma", [("🔥", 2)]),
            (MiraDemo.livenessId, MiraDemo.lukas, self.yesterday(17, 14), "Looks clean. I'll go through the Android version tonight", []),
            (MiraDemo.livenessId, nil, self.today(12, 31), "Thanks! I'll leave comments on the empty states", [("👍", 1)]),
            (MiraDemo.livenessId, MiraDemo.elena, self.today(12, 47), "Let's sync on Friday after the review", [("👍", 3)])
        ]
        return self.context.account.postbox.transaction { transaction -> Void in
            var peers: [Peer] = MiraDemo.people.map { MiraDemo.telegramUser($0) }
            peers.append(MiraDemo.group(id: MiraDemo.internalTeamId, title: "Internal Team", count: 6))
            peers.append(MiraDemo.group(id: MiraDemo.livenessId, title: "Liveness & Co", count: 4))
            updatePeersCustom(transaction: transaction, peers: peers, update: { _, updated in updated })

            for chatId in [MiraDemo.internalTeamId, MiraDemo.livenessId] {
                transaction.clearHistory(chatId, threadId: nil, minTimestamp: nil, maxTimestamp: nil, namespaces: .all, forEachMedia: nil)
            }
            // Members with their roles (Marco owns the group, Sophie and Elena are admins) and open reactions.
            let roles: [(EnginePeer.Id, [GroupParticipant])] = [
                (MiraDemo.internalTeamId, [
                    .creator(id: MiraDemo.marco.id, rank: nil),
                    .admin(id: MiraDemo.sophie.id, invitedBy: MiraDemo.marco.id, invitedAt: 0, rank: nil),
                    .admin(id: MiraDemo.elena.id, invitedBy: MiraDemo.marco.id, invitedAt: 0, rank: nil),
                    .member(id: MiraDemo.lukas.id, invitedBy: MiraDemo.marco.id, invitedAt: 0, rank: nil),
                    .member(id: accountPeerId, invitedBy: MiraDemo.marco.id, invitedAt: 0, rank: nil)
                ]),
                (MiraDemo.livenessId, [
                    .creator(id: MiraDemo.marco.id, rank: nil),
                    .member(id: MiraDemo.lukas.id, invitedBy: MiraDemo.marco.id, invitedAt: 0, rank: nil),
                    .member(id: MiraDemo.elena.id, invitedBy: MiraDemo.marco.id, invitedAt: 0, rank: nil),
                    .member(id: accountPeerId, invitedBy: MiraDemo.marco.id, invitedAt: 0, rank: nil)
                ])
            ]
            for (chatId, participants) in roles {
                transaction.updatePeerCachedData(peerIds: [chatId], update: { _, _ in
                    return CachedGroupData()
                        .withUpdatedParticipants(CachedGroupParticipants(participants: participants, version: 0))
                        .withUpdatedReactionSettings(.known(PeerReactionSettings(allowedReactions: .all, maxReactionCount: 11, starsAllowed: false)))
                })
            }

            var messages: [StoreMessage] = []
            for (chatId, author, timestamp, text, reactions) in history {
                var attributes: [MessageAttribute] = []
                if !reactions.isEmpty {
                    attributes.append(ReactionsMessageAttribute(canViewList: false, isTags: false, reactions: reactions.map { MessageReaction(value: .builtin($0.0), count: $0.1, chosenOrder: nil) }, recentPeers: [], topPeers: []))
                }
                messages.append(StoreMessage(peerId: chatId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: Int64.random(in: 1 ... Int64.max), groupingKey: nil, threadId: nil, timestamp: timestamp, flags: author == nil ? [] : [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: author?.id ?? accountPeerId, text: text, attributes: attributes, media: []))
            }
            let seededIds = transaction.addMessages(messages, location: .Random)

            for chatId in [MiraDemo.internalTeamId, MiraDemo.livenessId] {
                // No server history to load for these chats, and everything seeded counts as read.
                transaction.removeHole(peerId: chatId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: 1 ... (Int32.max - 1))
                transaction.resetIncomingReadStates([chatId: [
                    Namespaces.Message.Cloud: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 0, count: 0, markedUnread: false),
                    Namespaces.Message.Local: .idBased(maxIncomingReadId: 1_000_000, maxOutgoingReadId: 1_000_000, maxKnownId: 1_000_000, count: 0, markedUnread: false)
                ]])
                transaction.updatePeerChatListInclusion(chatId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
                if let lastId = seededIds.values.filter({ $0.peerId == chatId }).max() {
                    transaction.applyIncomingReadMaxId(lastId)
                }
            }
        }
    }

    /// Elena's travel photo and a sticker close yesterday's chat in Internal Team, so less text sits above "Today".
    private func seedYesterdayStickers() -> Signal<Void, NoError> {
        let postbox = self.context.account.postbox
        // The photo is a regular image message backed by a local resource, like the avatars.
        let photoResource = LocalFileMediaResource(fileId: 9_000_000_100_001)
        var photoSize = PixelDimensions(width: 853, height: 1280)
        if let image = UIImage(bundleImageName: "Avatar/DemoElenaPhoto"), let data = image.jpegData(compressionQuality: 0.85) {
            postbox.mediaBox.storeResourceData(photoResource.id, data: data, synchronous: true)
            photoSize = PixelDimensions(width: Int32(image.size.width * image.scale), height: Int32(image.size.height * image.scale))
        }
        let photo = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: 9_000_000_100_001), representations: [TelegramMediaImageRepresentation(dimensions: photoSize, resource: photoResource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        let elenaTime = self.yesterday(15, 54)
        let lukasTime = self.yesterday(15, 56)
        return self.context.engine.stickers.loadedStickerPack(reference: .name("UtyaDuck"), forceActualized: false)
        |> mapToSignal { pack -> Signal<[TelegramMediaFile], NoError> in
            switch pack {
            case .fetching:
                return .complete()
            case .none:
                return .single([])
            case let .result(_, items, _):
                let files = items.map { $0.file._parse() }
                func pick(_ emojis: [String], fallback: Int) -> TelegramMediaFile? {
                    let found = files.first(where: { file in
                        file.attributes.contains(where: { attribute in
                            if case let .Sticker(displayText, _, _) = attribute {
                                return emojis.contains(where: { displayText.contains($0) })
                            }
                            return false
                        })
                    })
                    return found ?? (files.count > fallback ? files[fallback] : nil)
                }
                // The duck with a paper plane, to go with Elena's travel photo.
                return .single([pick(["📨"], fallback: 26)].compactMap { $0 })
            }
        }
        |> take(1)
        |> timeout(5.0, queue: Queue.mainQueue(), alternate: .single([]))
        |> mapToSignal { files -> Signal<Void, NoError> in
            return postbox.transaction { transaction -> Void in
                let items: [(Person, Int32, Media, MessageTags)] = [(MiraDemo.elena, elenaTime, photo, .photoOrVideo)]
                let _ = (files, lukasTime)
                let messages = items.map { person, timestamp, media, tags in
                    // Everyone else loves the photo: ❤ and 🔥 from Sophie, Lukas and Marco.
                    StoreMessage(peerId: MiraDemo.internalTeamId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: Int64.random(in: 1 ... Int64.max), groupingKey: nil, threadId: nil, timestamp: timestamp, flags: [.Incoming], tags: tags, globalTags: [], localTags: [], forwardInfo: nil, authorId: person.id, text: "", attributes: [
                        ReactionsMessageAttribute(canViewList: false, isTags: false, reactions: [
                            MessageReaction(value: .builtin("\u{2764}"), count: 3, chosenOrder: nil),
                            MessageReaction(value: .builtin("🔥"), count: 3, chosenOrder: nil)
                        ], recentPeers: [], topPeers: [])
                    ], media: [media])
                }
                let ids = transaction.addMessages(messages, location: .Random)
                if let lastId = ids.values.max() {
                    transaction.applyIncomingReadMaxId(lastId)
                }
            }
        }
    }

    // MARK: - Storage

    private static func italic(_ text: String) -> TextEntitiesMessageAttribute {
        return TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< (text as NSString).length, type: .Italic)])
    }

    private func store(peerId: EnginePeer.Id, author: EnginePeer.Id, incoming: Bool, text: String, attributes: [MessageAttribute], media: [Media], timestamp: Int32) async -> MessageId? {
        let globallyUniqueId = Int64.random(in: 1 ... Int64.max)
        var tags: MessageTags = []
        if media.contains(where: { $0 is TelegramMediaFile }) {
            tags.insert(.file)
        }
        let message = StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: globallyUniqueId, groupingKey: nil, threadId: nil, timestamp: timestamp, flags: incoming ? [.Incoming] : [], tags: tags, globalTags: [], localTags: [], forwardInfo: nil, authorId: author, text: text, attributes: attributes, media: media)
        let result: MessageId?? = await self.value(self.context.account.postbox.transaction { transaction -> MessageId? in
            let ids = transaction.addMessages([message], location: .Random)
            guard let id = ids[globallyUniqueId] else {
                return nil
            }
            // Everything in the demo counts as read, so the chat opens without the "Unread Messages" divider.
            if incoming {
                transaction.applyIncomingReadMaxId(id)
            }
            return id
        })
        return result ?? nil
    }

    private func updateText(_ id: MessageId, text: String, extra: [MessageAttribute]) async {
        let _: Void? = await self.value(self.context.account.postbox.transaction { transaction -> Void in
            transaction.updateMessage(id, update: { message in
                var attributes = message.attributes.filter { !($0 is TextEntitiesMessageAttribute) && !($0 is ReplyMessageAttribute) }
                attributes.append(contentsOf: extra)
                return .update(StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: message.author?.id, text: text, attributes: attributes, media: message.media))
            })
        })
    }

    @MainActor
    private func addReaction(_ emoji: String, from peerId: EnginePeer.Id, to messageId: MessageId) async {
        var state = self.reactions[messageId] ?? ReactionState()
        if let index = state.counts.firstIndex(where: { $0.emoji == emoji }) {
            state.counts[index].peers.append(peerId)
        } else {
            state.counts.append((emoji, [peerId]))
        }
        self.reactions[messageId] = state
        await self.writeReactions(messageId)
    }

    private func writeReactions(_ messageId: MessageId) async {
        guard let state = self.reactions[messageId] else {
            return
        }
        let accountPeerId = self.context.account.peerId
        var entries = state.counts
        if let mine = state.mine {
            if let index = entries.firstIndex(where: { $0.emoji == mine }) {
                entries[index].peers.insert(accountPeerId, at: 0)
            } else {
                entries.insert((mine, [accountPeerId]), at: 0)
            }
        }
        let reactions = entries.map { MessageReaction(value: .builtin($0.emoji), count: Int32($0.peers.count), chosenOrder: $0.emoji == state.mine ? 0 : nil) }
        // Like the server: reactors' avatars only while there are three reactions or fewer, then counts.
        var recentPeers: [ReactionsMessageAttribute.RecentPeer] = []
        let total = entries.reduce(0) { $0 + $1.peers.count }
        for entry in entries where total <= 3 {
            for peerId in entry.peers {
                recentPeers.append(ReactionsMessageAttribute.RecentPeer(value: .builtin(entry.emoji), isLarge: false, isUnseen: false, isMy: peerId == accountPeerId, peerId: peerId, timestamp: nil))
            }
        }
        let attribute = ReactionsMessageAttribute(canViewList: false, isTags: false, reactions: reactions, recentPeers: recentPeers, topPeers: [])
        let _: Void? = await self.value(self.context.account.postbox.transaction { transaction -> Void in
            transaction.updateMessage(messageId, update: { message in
                var attributes = message.attributes.filter { !($0 is ReactionsMessageAttribute) && !($0 is PendingReactionsMessageAttribute) }
                attributes.append(attribute)
                return .update(StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: message.author?.id, text: message.text, attributes: attributes, media: message.media))
            })
        })
    }

    private func value<T>(_ signal: Signal<T, NoError>) async -> T? {
        return await withCheckedContinuation { continuation in
            let resumed = Atomic<Bool>(value: false)
            let _ = signal.start(next: { value in
                if !resumed.swap(true) {
                    continuation.resume(returning: value)
                }
            }, completed: {
                if !resumed.swap(true) {
                    continuation.resume(returning: nil)
                }
            })
        }
    }
}
