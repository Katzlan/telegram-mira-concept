import Foundation
import UIKit
import SwiftUI
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import AvatarNode
import TelegramPresentationData
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import ComponentFlow
import GlassBackgroundComponent

// Prototype: the assistant's side panel in a group.
//
// The panel holds a private thread with the assistant that belongs to this group (it is not the user's
// global chat with the bot). It slides in from the right while the group shifts left into a rounded,
// dimmed card that stays visible as a strip; the composer stays where it is and narrows into the panel.
// The thread lives on the device; the assistant's replies here are scripted for the prototype.

// MARK: - Thread

@available(iOS 17.0, *)
@MainActor
final class MiraGroupThread: ObservableObject {
    enum State: Equatable {
        case sent
        case thinking
        case streaming
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
        let time: String
        var state: State = .sent
        var fadingTail: Int = 0
        /// A sticker reply (Utya from Telegram's own pack) instead of text.
        var sticker: TelegramMediaFile? = nil

        static func == (lhs: Item, rhs: Item) -> Bool {
            return lhs.id == rhs.id && lhs.text == rhs.text && lhs.state == rhs.state && lhs.fadingTail == rhs.fadingTail && lhs.sticker?.fileId == rhs.sticker?.fileId
        }
    }

    /// Set by the panel: loads the sticker the assistant sends when asked for one.
    var stickerProvider: (() -> Signal<TelegramMediaFile?, NoError>)?

    @Published var items: [Item]
    @Published var draft = ""
    @Published var isWorking = false

    let groupTitle: String
    private var task: Task<Void, Never>?
    private var answerId: UUID?

    private static var threads: [EnginePeer.Id: MiraGroupThread] = [:]

    /// One thread per group, kept for the app session.
    static func thread(for groupId: EnginePeer.Id, title: String) -> MiraGroupThread {
        if let thread = self.threads[groupId] {
            return thread
        }
        let thread = MiraGroupThread(groupTitle: title)
        self.threads[groupId] = thread
        return thread
    }

    private init(groupTitle: String) {
        self.groupTitle = groupTitle
        // The thread opens with the assistant explaining its scope: it works with this group only.
        self.items = [
            Item(isUser: false, text: "Hi! This is your private thread with me for \(groupTitle). Here I work only with \(groupTitle): I can read this group's messages, but nothing you write here is shared with its members. Ask me to sum up the chat, find a message or check what the team agreed on.", time: Self.now()),
        ]
    }

    var suggestion: String { "Summarize today's \(self.groupTitle) chat" }
    var showsSuggestion: Bool { !self.isWorking && self.items.count == 1 }

    private static func now() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    func send() {
        let text = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !self.isWorking else {
            return
        }
        self.draft = ""
        withAnimation(.snappy) {
            self.items.append(Item(isUser: true, text: text, time: Self.now()))
        }
        self.task = Task { await self.answer(to: text) }
    }

    func stop() {
        self.task?.cancel()
        self.finish()
    }

    private func reply(to text: String) -> String {
        return "Thank you! Whenever something comes up, like finding a message, pulling a discussion together or checking the calendar, just write to me."
    }

    private func asksForSticker(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["sticker", "duck", "utya", "raccoon"].contains(where: { lower.contains($0) })
    }

    private func loadSticker() async -> TelegramMediaFile? {
        guard let provider = self.stickerProvider else { return nil }
        return await withCheckedContinuation { continuation in
            let resumed = Atomic<Bool>(value: false)
            let _ = (provider() |> take(1)).start(next: { file in
                if !resumed.swap(true) { continuation.resume(returning: file) }
            }, completed: {
                if !resumed.swap(true) { continuation.resume(returning: nil) }
            })
        }
    }

    private func answer(to question: String) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        self.isWorking = true
        let item = Item(isUser: false, text: "", time: Self.now(), state: .thinking)
        self.answerId = item.id
        withAnimation(.snappy) { self.items.append(item) }
        if self.asksForSticker(question) {
            async let sticker = self.loadSticker()
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            let file = await sticker
            guard !Task.isCancelled else { return }
            if let file {
                // The thinking line turns into the sticker.
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    self.update(item.id) { $0.sticker = file; $0.state = .sent }
                }
                self.answerId = nil
                self.isWorking = false
                return
            }
        } else {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
        }
        guard !Task.isCancelled else { return }

        withAnimation(.snappy) { self.update(item.id) { $0.state = .streaming; $0.fadingTail = 10 } }
        let characters = Array(self.reply(to: question))
        var index = 0
        while index < characters.count {
            guard !Task.isCancelled else { return }
            let next = min(index + Int.random(in: 1 ... 3), characters.count)
            let chunk = String(characters[index ..< next])
            self.update(item.id) { $0.text += chunk }
            index = next
            try? await Task.sleep(nanoseconds: UInt64.random(in: 22_000_000 ... 40_000_000))
        }
        for tail in stride(from: 9, through: 0, by: -1) {
            guard !Task.isCancelled else { return }
            self.update(item.id) { $0.fadingTail = tail }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        self.finish()
    }

    private func finish() {
        if let id = self.answerId {
            if let i = self.items.firstIndex(where: { $0.id == id }), self.items[i].text.isEmpty, self.items[i].sticker == nil {
                withAnimation(.snappy) { _ = self.items.remove(at: i) }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { self.update(id) { $0.state = .sent; $0.fadingTail = 0 } }
            }
        }
        self.answerId = nil
        self.isWorking = false
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
        change(&self.items[i])
    }
}

// MARK: - Controller

@available(iOS 17.0, *)
final class MiraSidePanelController: ViewController {
    static let stripWidth: CGFloat = 64.0
    static let cornerRadius: CGFloat = 54.0

    private let context: AccountContext
    private let assistant: EnginePeer
    private weak var groupController: ChatControllerImpl?
    private let groupPeerId: EnginePeer.Id?
    private let thread: MiraGroupThread
    private let panelState = MiraPanelState()
    /// The same spring for UIKit (panel, group) and SwiftUI (composer), so everything moves together.
    static let springDuration: TimeInterval = 0.45
    static let swiftUISpring = Animation.spring(duration: MiraSidePanelController.springDuration, bounce: 0.0)


    /// The dragged sticker lives in plain UIKit above everything and is placed straight at the finger,
    /// so no SwiftUI layout or animation can move it elsewhere.
    private let dragLayer = UIView()
    private var draggedSticker: (file: TelegramMediaFile, view: StickerView.StickerContainer)?

    private func updateDraggedSticker() {
        guard let file = self.panelState.dragSticker else {
            if let dragged = self.draggedSticker {
                self.draggedSticker = nil
                UIView.animate(withDuration: 0.15, animations: {
                    dragged.view.alpha = 0.0
                }, completion: { _ in
                    dragged.view.removeFromSuperview()
                })
            }
            return
        }
        let view: StickerView.StickerContainer
        if let dragged = self.draggedSticker, dragged.file.fileId == file.fileId {
            view = dragged.view
        } else {
            self.draggedSticker?.view.removeFromSuperview()
            view = StickerView.StickerContainer()
            view.setup(context: self.context, file: file)
            view.bounds = CGRect(x: 0.0, y: 0.0, width: 150.0, height: 150.0)
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.25
            view.layer.shadowRadius = 16.0
            view.layer.shadowOffset = CGSize(width: 0.0, height: 6.0)
            view.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
            self.dragLayer.addSubview(view)
            self.draggedSticker = (file, view)
        }
        view.center = self.view.convert(self.panelState.dragPoint, from: nil)
        let scale: CGFloat = self.panelState.isOverGroup ? 0.8 : 1.05
        if abs(view.transform.a - scale) > 0.01 {
            UIView.animate(withDuration: 0.25, delay: 0.0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            })
        }
    }

    /// Hides the group's composer with an empty mask instead of alpha: native glass re-materializes (flashes)
    /// when its alpha comes back from zero, a mask keeps it rendered.
    private func setGroupComposerHidden(_ hidden: Bool) {
        guard let view = self.groupController?.chatDisplayNode.inputPanelContainerNode.view else { return }
        view.layer.mask = hidden ? CALayer() : nil
    }

    /// The panel (background and thread) is one UIKit layer, so everything in it moves in lockstep with the group.
    private let panelContainer = UIView()
    private var panelHost: UIHostingController<MiraPanelContentHost>?
    /// The composer and the dragged sticker live above the panel, full width.
    private var overlayHost: UIHostingController<MiraPanelRootView>?
    private let stripView = UIView()
    private let dimView = UIView()
    private var didAppear = false

    init(context: AccountContext, assistant: EnginePeer, groupController: ChatControllerImpl) {
        self.context = context
        self.assistant = assistant
        self.groupController = groupController
        let groupPeer = groupController.presentationInterfaceState.renderedPeer?.peer
        let title = groupPeer.flatMap { EnginePeer($0).compactDisplayTitle } ?? "this chat"
        self.thread = MiraGroupThread.thread(for: groupPeer?.id ?? assistant.id, title: title)
        self.groupPeerId = groupPeer?.id
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore

        let engine = context.engine
        self.thread.stickerProvider = {
            // Utya, from Telegram's own sticker pack: a dancing one if the pack has it.
            return engine.stickers.loadedStickerPack(reference: .name("UtyaDuck"), forceActualized: false)
            |> mapToSignal { pack -> Signal<TelegramMediaFile?, NoError> in
                switch pack {
                case .fetching:
                    return .complete()
                case .none:
                    return .single(nil)
                case let .result(_, items, _):
                    let files = items.map { $0.file._parse() }
                    let dancing = files.first(where: { file in
                        file.attributes.contains(where: { attribute in
                            if case let .Sticker(displayText, _, _) = attribute {
                                return ["💃", "🕺", "🥳", "🎉"].contains(where: { displayText.contains($0) })
                            }
                            return false
                        })
                    })
                    return .single(dancing ?? files.first)
                }
            }
        }
        self.panelState.onDrop = { [weak self] file, point in
            self?.handleDrop(file: file, point: point)
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .clear
        self.displayNodeDidLoad()
    }

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()

        // The group's strip: a tap closes the panel.
        self.stripView.backgroundColor = .clear
        self.stripView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.stripTapped)))
        self.view.addSubview(self.stripView)

        // Insets come from Telegram's layout (see containerLayoutUpdated), not from UIKit's safe area.
        let panelHost = UIHostingController(rootView: MiraPanelContentHost(
            context: self.context,
            assistant: self.assistant,
            thread: self.thread,
            state: self.panelState,
            close: { [weak self] in self?.close() },
            openApp: { [weak self] in self?.openAssistantApp() }
        ))
        panelHost.view.backgroundColor = .clear
        panelHost.safeAreaRegions = []
        self.panelContainer.backgroundColor = .white
        self.panelContainer.layer.cornerRadius = Self.cornerRadius
        self.panelContainer.layer.cornerCurve = .continuous
        self.panelContainer.clipsToBounds = true
        self.addChild(panelHost)
        self.panelContainer.addSubview(panelHost.view)
        panelHost.didMove(toParent: self)
        self.panelHost = panelHost
        self.view.addSubview(self.panelContainer)

        let overlayHost = UIHostingController(rootView: MiraPanelRootView(
            context: self.context,
            thread: self.thread,
            state: self.panelState
        ))
        overlayHost.view.backgroundColor = .clear
        overlayHost.safeAreaRegions = []
        self.addChild(overlayHost)
        self.view.addSubview(overlayHost.view)
        overlayHost.didMove(toParent: self)
        self.overlayHost = overlayHost

        self.dragLayer.isUserInteractionEnabled = false
        self.view.addSubview(self.dragLayer)

        self.dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.12)
        self.dimView.alpha = 0.0
    }

    @objc private func stripTapped() {
        self.close()
    }

    private static let composerBandHeight: CGFloat = 40.0 + 20.0

    /// The overlay covers only the composer band, or the whole screen while a sticker is dragged,
    /// so it never takes touches meant for the panel.
    private func layoutOverlay(size: CGSize) {
        guard let overlay = self.overlayHost?.view else { return }
        let height = Self.composerBandHeight + max(0.0, self.panelState.composerBottom)
        overlay.frame = CGRect(x: 0.0, y: size.height - height, width: size.width, height: height)
        self.dragLayer.frame = CGRect(origin: .zero, size: size)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let panelFrame = CGRect(x: Self.stripWidth, y: 0.0, width: layout.size.width - Self.stripWidth, height: layout.size.height)
        self.panelContainer.bounds = CGRect(origin: .zero, size: panelFrame.size)
        self.panelContainer.center = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        self.panelHost?.view.frame = CGRect(origin: .zero, size: panelFrame.size)
        self.stripView.frame = CGRect(x: 0.0, y: 0.0, width: Self.stripWidth, height: layout.size.height)
        let top = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        let bottom = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        if self.panelState.topInset != top || self.panelState.bottomInset != bottom {
            let animated = self.didAppear
            if animated {
                withAnimation(.easeOut(duration: transition.isAnimated ? 0.3 : 0.25)) {
                    self.panelState.topInset = top
                    self.panelState.bottomInset = bottom
                }
            } else {
                self.panelState.topInset = top
                self.panelState.bottomInset = bottom
            }
        }
        self.layoutOverlay(size: layout.size)
        if !self.didAppear {
            self.didAppear = true
            self.panelState.onDragChanged = { [weak self] in
                self?.updateDraggedSticker()
            }
            self.panelContainer.transform = CGAffineTransform(translationX: panelFrame.width + Self.stripWidth, y: 0.0)
            // The panel's composer looks exactly like the group's one and sits in the same place, so they swap in
            // one frame. (A crossfade stacks the two glass shadows and makes the shadow blink.)
            self.setGroupComposerHidden(true)
            self.groupController?.ignoresKeyboardForSidePanel = true
            let width = layout.size.width
            DispatchQueue.main.async {
                self.shiftGroup(open: true, width: width)
                withAnimation(Self.swiftUISpring) {
                    self.panelState.isOpen = true
                }
                withAnimation(Self.swiftUISpring) {
                    self.panelState.composerOpen = true
                }
            }
        }
    }

    /// Opens Mira's mini app: the real @mira bot's main app (in the demo too, where the Mira in the thread is fictional).
    private func openAssistantApp() {
        let context = self.context
        let _ = (context.engine.peers.resolvePeerByName(name: MiraAssistant.assistantUsernames[0], referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            guard case let .result(peer) = result else {
                return .complete()
            }
            return .single(peer)
        }
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, let peer, let groupController = self.groupController else {
                return
            }
            // The mini app opens in the chat's navigation, so the panel closes first.
            self.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDuration) {
                ChatControllerImpl.presentBotApp(context: context, parentController: groupController, botApp: nil, botPeer: peer, payload: nil, mode: .generic)
            }
        })
    }

    func close() {
        guard self.panelState.isOpen else { return }
        self.view.endEditing(true)
        withAnimation(Self.swiftUISpring) {
            self.panelState.isOpen = false
            self.panelState.composerOpen = false
        }
        self.shiftGroup(open: false, width: self.view.bounds.width)
        self.panelState.onDragChanged = nil
        // Hand back once the composer has settled: the group's composer appears and the panel's one goes away
        // in the same frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDuration + 0.05) { [weak self] in
            guard let self else { return }
            self.groupController?.ignoresKeyboardForSidePanel = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.setGroupComposerHidden(false)
            self.overlayHost?.view.isHidden = true
            CATransaction.commit()
            DispatchQueue.main.async {
                self.dismiss()
            }
        }
    }

    /// Dropping the sticker on the group's strip closes the panel and sends the sticker to the group.
    private func handleDrop(file: TelegramMediaFile, point: CGPoint) {
        guard point.x < Self.stripWidth + MiraPanelState.dropSlack, let groupPeerId = self.groupPeerId else {
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.close()
        let account = self.context.account
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // In the demo the group is fictional: the sticker is stored on the device (see MiraDemo).
            if MiraDemo.isDemoChat(groupPeerId), let demo = MiraDemo.shared {
                demo.sendSticker(file)
                return
            }
            let _ = enqueueMessages(account: account, peerId: groupPeerId, messages: [
                .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            ]).start()
        }
    }

    /// The group slides left into a rounded, dimmed card; its own composer hides because the panel's
    /// composer takes its place.
    private func shiftGroup(open: Bool, width: CGFloat) {
        guard let groupController = self.groupController, let groupView = groupController.view else { return }
        if self.dimView.superview !== groupView {
            groupView.addSubview(self.dimView)
        }
        self.dimView.frame = groupView.bounds
        groupView.layer.cornerCurve = .continuous
        groupView.layer.masksToBounds = true
        let panel = self.panelContainer
        UIView.animate(springDuration: Self.springDuration, bounce: 0.0, initialSpringVelocity: 0.0, delay: 0.0, options: [.beginFromCurrentState], animations: {
            groupView.transform = CGAffineTransform(translationX: open ? -(width - Self.stripWidth) : 0.0, y: 0.0)
            panel.transform = open ? .identity : CGAffineTransform(translationX: width, y: 0.0)
            groupView.layer.cornerRadius = open ? Self.cornerRadius : 0.0
            self.dimView.alpha = open ? 1.0 : 0.0
            self.dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.12)
        }, completion: { _ in
            if !open {
                groupView.layer.masksToBounds = false
                self.dimView.removeFromSuperview()
            }
        })
    }
}

@available(iOS 17.0, *)
final class MiraPanelState: ObservableObject {
    @Published var isOpen = false
    /// The composer moves into the panel only after the group's composer has dissolved into it, and moves
    /// back before the group's one reappears, so the two never show side by side.
    @Published var composerOpen = false
    /// Telegram's layout insets: status bar on top, home indicator or keyboard at the bottom.
    @Published var topInset: CGFloat = 0.0
    @Published var bottomInset: CGFloat = 0.0
    /// Distance from the screen bottom to the composer, as in the group: over the home indicator,
    /// a little above the keyboard.
    /// Without the keyboard the group's composer sits 28 pt above the screen edge (measured on iPhone 17 Pro).
    var composerBottom: CGFloat { self.bottomInset > 60.0 ? self.bottomInset + 8.0 : GroupComposer.bottom }

    /// The sticker being dragged out of the panel, and the finger position in screen coordinates.
    @Published var dragSticker: TelegramMediaFile? {
        didSet { self.onDragChanged?() }
    }
    var onDragChanged: (() -> Void)?
    @Published var dragPoint: CGPoint = .zero {
        didSet { self.onDragChanged?() }
    }
    var onDrop: ((TelegramMediaFile, CGPoint) -> Void)?

    /// How far right of the strip a drop still lands on the group.
    static let dropSlack: CGFloat = 40.0
    var isOverGroup: Bool { self.dragSticker != nil && self.dragPoint.x < MiraSidePanelController.stripWidth + Self.dropSlack }
}

// MARK: - Views

private let accent = Color(red: 0.0, green: 0.48, blue: 1.0)
private let secondary = Color(red: 0.56, green: 0.56, blue: 0.58)
private let inset: CGFloat = 16.0

/// The panel itself: thread and header on the white background (the background is the UIKit container).
@available(iOS 17.0, *)
struct MiraPanelContentHost: View {
    let context: AccountContext
    let assistant: EnginePeer
    @ObservedObject var thread: MiraGroupThread
    @ObservedObject var state: MiraPanelState
    let close: () -> Void
    let openApp: () -> Void

    var body: some View {
        MiraPanelContent(context: context, assistant: assistant, thread: thread, panelState: state, bottomInset: state.bottomInset, close: close, openApp: openApp)
            .padding(.top, state.topInset)
            .padding(.bottom, state.bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where the group's composer sits (ChatTextInputPanelNode with the "@" button), so the panel's composer
/// starts exactly on top of it.
enum GroupComposer {
    static let height: CGFloat = 40.0
    static let spacing: CGFloat = 6.0
    static let mentionX: CGFloat = 26.0
    static let leading: CGFloat = mentionX + height + spacing
    static let trailing: CGFloat = 26.0
    static let bottom: CGFloat = 28.0
}

/// Above the panel: the composer (stays in place, narrows into the panel) and the dragged sticker.
@available(iOS 17.0, *)
struct MiraPanelRootView: View {
    let context: AccountContext
    @ObservedObject var thread: MiraGroupThread
    @ObservedObject var state: MiraPanelState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                let composerY = geo.size.height - state.composerBottom - GroupComposer.height / 2.0
                // The group's "@" stays where it was and fades out: mentions belong to the group, not this thread.
                Image(systemName: "at")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: GroupComposer.height, height: GroupComposer.height)
                    .background(Circle().fill(Color(red: 0.0, green: 0.478, blue: 1.0)))
                    .scaleEffect(state.composerOpen ? 0.2 : 1.0)
                    .opacity(state.composerOpen ? 0.0 : 1.0)
                    .position(x: GroupComposer.mentionX + GroupComposer.height / 2.0, y: composerY)
                    .allowsHitTesting(false)
                MiraComposer(thread: thread, theme: context.sharedContext.currentPresentationData.with { $0 }.theme)
                    .padding(.leading, state.composerOpen ? MiraSidePanelController.stripWidth + inset : GroupComposer.leading)
                    .padding(.trailing, state.composerOpen ? inset : GroupComposer.trailing)
                    .frame(width: geo.size.width, height: GroupComposer.height)
                    .position(x: geo.size.width / 2.0, y: composerY)
            }
        }
    }
}

@available(iOS 17.0, *)
private struct MiraPanelContent: View {
    let context: AccountContext
    let assistant: EnginePeer
    @ObservedObject var thread: MiraGroupThread
    @ObservedObject var panelState: MiraPanelState
    let bottomInset: CGFloat
    let close: () -> Void
    let openApp: () -> Void

    @State private var query = ""

    /// The thread, or only the messages that contain the search text.
    private var visibleItems: [MiraGroupThread.Item] {
        let query = self.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return thread.items
        }
        return thread.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Like a Telegram chat: the thread sits on the bottom, right above the composer, and grows upwards.
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Spacer(minLength: 0)
                        if !query.isEmpty && visibleItems.isEmpty {
                            Text("No results")
                                .font(.system(size: 15))
                                .foregroundColor(secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        }
                        ForEach(visibleItems) { item in
                            MiraThreadRow(context: context, assistant: assistant, item: item, panelState: panelState)
                                .id(item.id)
                        }
                        if thread.showsSuggestion && query.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(secondary)
                                Text(thread.suggestion)
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .padding(.leading, 4)
                            .onTapGesture { thread.draft = thread.suggestion }
                        }
                        // The space under the last message clears the composer; scrolling to "bottom" includes it.
                        Color.clear.frame(height: 64).id("bottom")
                    }
                    .padding(.horizontal, inset)
                    .padding(.top, 8)
                    .frame(minHeight: viewport.size.height, alignment: .bottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The newest message stays right above the composer: when the keyboard shrinks the view and while
                // an answer grows.
                .modifier(StickToBottom())
                .onChange(of: thread.items) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: thread.isWorking) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                // The keyboard pushes the thread up so the newest message stays above the composer.
                .onChange(of: bottomInset) { _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    // Once more after the inset has been laid out (the suggestion bar can raise the keyboard later).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                VStack(spacing: 0) {
                    Text(assistant.compactDisplayTitle).font(.system(size: 16, weight: .semibold))
                    // The lock says this thread is private and scoped to this group only.
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                        Text(thread.groupTitle).font(.system(size: 12))
                    }
                    .foregroundColor(secondary)
                }
                .padding(.horizontal, 28)
                .frame(height: 44)
                .miraGlass(Capsule())
                Spacer()
                // Mira's avatar opens her mini app.
                Button(action: openApp) {
                    PeerAvatarView(context: context, peer: assistant, size: 34)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .miraGlass(Circle())
            }
            // Searches this thread's messages.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(secondary)
                TextField("Search", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Capsule().fill(Color.black.opacity(0.06)))
        }
        .padding(.horizontal, inset)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

@available(iOS 17.0, *)
private struct MiraThreadRow: View {
    let context: AccountContext
    let assistant: EnginePeer
    let item: MiraGroupThread.Item
    @ObservedObject var panelState: MiraPanelState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.isUser {
                AccountAvatarView(context: context, size: 36)
            } else {
                PeerAvatarView(context: context, peer: assistant, size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.isUser ? "You" : assistant.compactDisplayTitle).font(.system(size: 15, weight: .semibold))
                    Text(item.time).font(.system(size: 12)).foregroundColor(secondary)
                }
                content
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.state {
        case .thinking:
            HStack(spacing: 6) {
                MiraMascot(size: 16)
                ShimmerText(text: "Thinking…")
            }
        case .streaming, .sent:
            if let sticker = item.sticker {
                // Hold, then drag the sticker onto the group on the left to send it there.
                StickerView(context: context, file: sticker, onHold: { phase, point in
                    switch phase {
                    case .began:
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        panelState.dragPoint = point
                        withAnimation(.spring(response: 0.3)) { panelState.dragSticker = sticker }
                    case .moved:
                        panelState.dragPoint = point
                    case .ended:
                        panelState.onDrop?(sticker, point)
                        withAnimation(.spring(response: 0.3)) { panelState.dragSticker = nil }
                    }
                })
                .frame(width: 160, height: 160)
                .opacity(panelState.dragSticker == nil ? 1.0 : 0.3)
                .transition(.scale(scale: 0.4, anchor: .topLeading).combined(with: .opacity))
            } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(fadedText)
                    .font(.system(size: 16))
                    .fixedSize(horizontal: false, vertical: true)
                if !item.isUser && item.state == .sent {
                    Text("\(assistant.compactDisplayTitle) is AI and can make mistakes.")
                        .font(.system(size: 12))
                        .foregroundColor(secondary)
                }
            }
            }
        }
    }

    private var fadedText: AttributedString {
        var s = AttributedString(item.text)
        guard item.fadingTail > 0 else { return s }
        let count = s.characters.count
        let tail = min(item.fadingTail, count)
        var index = s.characters.index(s.startIndex, offsetBy: count - tail)
        for k in 0 ..< tail {
            let next = s.characters.index(after: index)
            s[index ..< next].foregroundColor = Color.primary.opacity(Double(tail - k) / Double(tail + 1))
            index = next
        }
        return s
    }
}

@available(iOS 17.0, *)
private struct MiraComposer: View {
    @ObservedObject var thread: MiraGroupThread
    /// Built from the same parts as the group's composer (Telegram's glass, icons and colors),
    /// so handing over between the two is invisible.
    let theme: PresentationTheme

    private func icon(_ name: String, color: UIColor) -> some View {
        Image(uiImage: generateTintedImage(image: UIImage(bundleImageName: name), color: color) ?? UIImage())
    }

    var body: some View {
        let panel = theme.chat.inputPanel
        HStack(alignment: .bottom, spacing: GroupComposer.spacing) {
            icon("Chat/Input/Text/IconAttachment", color: panel.panelControlColor)
                .frame(width: GroupComposer.height, height: GroupComposer.height)
                .background(TelegramGlass(theme: theme))
            HStack(spacing: 4) {
                MiraTextField(text: $thread.draft, placeholderColor: panel.inputPlaceholderColor, textColor: panel.inputTextColor, onReturn: { thread.send() })
                    .frame(height: GroupComposer.height)
                icon("Chat/Input/Text/AccessoryIconStickers", color: panel.inputControlColor)
                    .frame(width: 24, height: 24)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: GroupComposer.height)
            .background(TelegramGlass(theme: theme))
            if thread.isWorking {
                Button(action: { thread.stop() }) {
                    RoundedRectangle(cornerRadius: 3.5).fill(Color(panel.panelControlColor))
                        .frame(width: 14, height: 14)
                        .frame(width: GroupComposer.height, height: GroupComposer.height)
                }
                .buttonStyle(.plain)
                .background(TelegramGlass(theme: theme))
            } else if thread.draft.isEmpty {
                icon("Chat/Input/Text/IconMicrophone", color: panel.panelControlColor)
                    .frame(width: GroupComposer.height, height: GroupComposer.height)
                    .background(TelegramGlass(theme: theme))
            } else {
                Button(action: { thread.send() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: GroupComposer.height, height: GroupComposer.height)
                        .background(Circle().fill(Color(panel.actionControlFillColor)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Keeps a scroll view pinned to its end when its content or viewport size changes.
@available(iOS 17.0, *)
private struct StickToBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Telegram's own glass (the one the chat composer uses), as a capsule filling the view.
@available(iOS 17.0, *)
private struct TelegramGlass: UIViewRepresentable {
    let theme: PresentationTheme

    final class Host: UIView {
        // Inside a container, like in the chat composer: the container draws the glass's soft shadow.
        let container = GlassBackgroundContainerView()
        let glass = GlassBackgroundView(frame: .zero)
        var theme: PresentationTheme?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.isUserInteractionEnabled = false
            self.addSubview(self.container)
            self.container.contentView.addSubview(self.glass)
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let theme = self.theme, self.bounds.width > 0.0 else { return }
            self.container.frame = self.bounds
            self.container.update(size: self.bounds.size, isDark: theme.overallDarkAppearance, transition: .immediate)
            self.glass.frame = self.bounds
            self.glass.update(size: self.bounds.size, cornerRadius: self.bounds.height * 0.5, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: true, transition: .immediate)
        }
    }

    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.theme = self.theme
        return host
    }

    func updateUIView(_ host: Host, context: Context) {
        host.theme = self.theme
        host.setNeedsLayout()
    }
}

/// A plain UITextField: sending never resigns it, so the keyboard stays up.
@available(iOS 17.0, *)
private struct MiraTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholderColor: UIColor = .placeholderText
    var textColor: UIColor = .label
    var onReturn: () -> Void

    /// Always asks for the US English keyboard, so the demo types in English.
    final class EnglishTextField: UITextField {
        override var textInputMode: UITextInputMode? {
            return UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage == "en-US" }) ?? super.textInputMode
        }
    }

    func makeUIView(context: Context) -> UITextField {
        let field = EnglishTextField()
        field.attributedPlaceholder = NSAttributedString(string: "Message", attributes: [.foregroundColor: placeholderColor, .font: UIFont.systemFont(ofSize: 17)])
        field.textColor = textColor
        field.font = .systemFont(ofSize: 17)
        field.returnKeyType = .send
        field.autocorrectionType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MiraTextField
        init(parent: MiraTextField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }
    }
}

// MARK: - Avatars (Telegram's AvatarNode inside SwiftUI)

@available(iOS 17.0, *)
private struct PeerAvatarView: UIViewRepresentable {
    let context: AccountContext
    let peer: EnginePeer
    let size: CGFloat

    func makeUIView(context _: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        let node = AvatarNode(font: avatarPlaceholderFont(size: floor(size * 0.42)))
        node.frame = container.bounds
        node.setPeer(context: self.context, theme: self.context.sharedContext.currentPresentationData.with({ $0 }).theme, peer: self.peer, displayDimensions: CGSize(width: size, height: size))
        container.addSubview(node.view)
        return container
    }

    func updateUIView(_ uiView: UIView, context _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context _: Context) -> CGSize? {
        return CGSize(width: size, height: size)
    }
}

@available(iOS 17.0, *)
private struct AccountAvatarView: View {
    let context: AccountContext
    let size: CGFloat
    @State private var peer: EnginePeer?

    var body: some View {
        Group {
            if let peer {
                PeerAvatarView(context: context, peer: peer, size: size)
            } else {
                Circle().fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> deliverOnMainQueue).start(next: { value in
                self.peer = value
            })
        }
    }
}

// MARK: - Glass, shimmer, mascot

@available(iOS 17.0, *)
private extension View {
    @ViewBuilder
    func miraGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.interactive(), in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }
}

@available(iOS 17.0, *)
private struct ShimmerText: View {
    let text: String

    var body: some View {
        let label = Text(text).font(.system(size: 16))
        return label
            .lineLimit(1)
            .foregroundColor(secondary.opacity(0.55))
            .overlay {
                TimelineView(.animation) { timeline in
                    ShimmerBand(label: label, phase: (timeline.date.timeIntervalSinceReferenceDate / 1.6).truncatingRemainder(dividingBy: 1))
                }
            }
    }
}

@available(iOS 17.0, *)
private struct ShimmerBand: View {
    let label: SwiftUI.Text
    let phase: Double

    var body: some View {
        GeometryReader { geo in
            let band = geo.size.width * 0.45
            let x = -band + (geo.size.width + band * 2) * phase
            label
                .foregroundColor(Color(white: 0.28))
                .mask(alignment: .leading) {
                    LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: x - band / 2)
                }
        }
    }
}

@available(iOS 17.0, *)
private struct MiraMascot: View {
    var size: CGFloat = 18
    var color = Color(white: 0.42)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let blink = t.truncatingRemainder(dividingBy: 2.8) < 0.14
            ZStack {
                SpikyBlob(spikes: 9)
                    .fill(color)
                    .frame(width: size * 0.86, height: size * 0.86)
                    .rotationEffect(.degrees(t * 45))
                    .scaleEffect(1 + 0.04 * sin(t * 5))
                HStack(spacing: size * 0.13) {
                    Capsule().fill(Color.white).frame(width: size * 0.13, height: blink ? size * 0.03 : size * 0.12)
                    Capsule().fill(Color.white).frame(width: size * 0.13, height: blink ? size * 0.03 : size * 0.12)
                }
                .offset(y: -size * 0.02)
            }
            .frame(width: size, height: size)
        }
    }
}

@available(iOS 17.0, *)
private struct SpikyBlob: Shape {
    var spikes: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        let steps = 180
        for i in 0 ... steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let bump = pow((1 + cos(Double(spikes) * a)) / 2, 3)
            let r = radius * (0.68 + 0.32 * bump)
            let p = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}


// MARK: - Animated sticker (Telegram's sticker node inside SwiftUI)

@available(iOS 17.0, *)
struct StickerView: UIViewRepresentable {
    enum HoldPhase { case began, moved, ended }

    let context: AccountContext
    let file: TelegramMediaFile
    var onHold: ((HoldPhase, CGPoint) -> Void)? = nil

    func makeUIView(context _: Context) -> StickerContainer {
        let container = StickerContainer()
        container.setup(context: self.context, file: self.file)
        container.onHold = self.onHold
        return container
    }

    func updateUIView(_ uiView: StickerContainer, context _: Context) {
        uiView.onHold = self.onHold
    }

    final class StickerContainer: UIView {
        private var node: DefaultAnimatedStickerNodeImpl?
        private var fetchDisposable: Disposable?
        var onHold: ((HoldPhase, CGPoint) -> Void)? {
            didSet { self.updateGesture() }
        }
        private var press: UILongPressGestureRecognizer?
        private weak var lockedScrollView: UIScrollView?

        func setup(context: AccountContext, file: TelegramMediaFile) {
            let node = DefaultAnimatedStickerNodeImpl(lottieSettings: context.lottieRenderingSettings)
            self.node = node
            self.addSubview(node.view)
            node.setup(source: AnimatedStickerResourceSource(account: context.account, resource: file.resource, isVideo: file.isVideoSticker), width: 320, height: 320, playbackMode: .loop, mode: .direct(cachePathPrefix: nil))
            node.visibility = true
            self.fetchDisposable = freeMediaFileInteractiveFetched(account: context.account, userLocation: .other, fileReference: .standalone(media: file)).start()
        }

        deinit {
            self.fetchDisposable?.dispose()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            self.node?.frame = self.bounds
            self.node?.updateLayout(size: self.bounds.size)
        }

        private func updateGesture() {
            if self.onHold != nil, self.press == nil {
                let press = UILongPressGestureRecognizer(target: self, action: #selector(self.handle(_:)))
                press.minimumPressDuration = 0.25
                press.allowableMovement = 30
                self.addGestureRecognizer(press)
                self.press = press
            }
        }

        @objc private func handle(_ press: UILongPressGestureRecognizer) {
            let point = press.location(in: nil)
            switch press.state {
            case .began:
                var view = self.superview
                while let current = view, !(current is UIScrollView) { view = current.superview }
                if let scroll = view as? UIScrollView {
                    scroll.isScrollEnabled = false
                    self.lockedScrollView = scroll
                }
                self.onHold?(.began, point)
            case .changed:
                self.onHold?(.moved, point)
            case .ended, .cancelled, .failed:
                self.lockedScrollView?.isScrollEnabled = true
                self.lockedScrollView = nil
                self.onHold?(.ended, point)
            default:
                break
            }
        }
    }
}
