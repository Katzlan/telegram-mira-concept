import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

/// Prototype: first-class AI assistants in group chats.
///
/// Telegram already lets a bot that is mentioned in a group answer that message, streaming its reply
/// ("Thinking…", then the text). This prototype makes such assistants easy to reach:
/// - the mention list offers them first in every group, even when they are not members,
///   with an "AI" badge and a subtitle;
/// - typing "@mira …" at the start of a message no longer turns into an inline-bot query.
///
/// The assistants are real bots resolved by username; nothing is mocked.
/// Behind the Debug Settings switch "AI assistants in groups" (`ExperimentalUISettings.miraAssistant`).
enum MiraAssistant {
    /// Usernames of AI assistants promoted in groups. A real implementation would get this from the server
    /// (for example a bot flag), the client only needs the list.
    static let assistantUsernames: [String] = ["mira"]

    static let subtitle = "AI assistant"

    static func isEnabled(_ context: AccountContext) -> Bool {
        return context.sharedContext.immediateExperimentalUISettings.miraAssistant
    }

    /// Assistants are offered in groups and supergroups (including forum topics), not in private chats or channels.
    static func canAssist(in peer: EngineRawPeer?) -> Bool {
        if peer is TelegramGroup {
            return true
        }
        if let channel = peer as? TelegramChannel, case .group = channel.info {
            return true
        }
        return false
    }

    static func isAssistantUsername(_ name: String) -> Bool {
        let name = (name.hasPrefix("@") ? String(name.dropFirst()) : name).lowercased()
        return self.assistantUsernames.contains(name)
    }

    static func isAssistant(_ peer: EnginePeer) -> Bool {
        guard case let .user(user) = peer, user.botInfo != nil, let username = peer.addressName else {
            return false
        }
        return self.isAssistantUsername(username)
    }

    // MARK: - Resolving the assistant bots

    private static let resolved = Atomic<[String: EnginePeer]>(value: [:])

    /// Assistant bots whose username starts with the typed query (all of them for a bare "@").
    /// Resolved once by username, then served from memory.
    static func assistantPeers(context: AccountContext, matching query: String) -> Signal<[EnginePeer], NoError> {
        let query = query.lowercased()
        // In the demo Mira is fictional too (see MiraDemo).
        if MiraDemo.isRequested {
            return .single(query.isEmpty || "mira".hasPrefix(query) ? [MiraDemo.miraPeer] : [])
        }
        let names = self.assistantUsernames.filter { query.isEmpty || $0.hasPrefix(query) }
        if names.isEmpty {
            return .single([])
        }
        let signals: [Signal<EnginePeer?, NoError>] = names.map { name in
            if let cached = self.resolved.with({ $0[name] }) {
                return .single(cached)
            }
            return context.engine.peers.resolvePeerByName(name: name, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                guard case let .result(peer) = result else {
                    return .complete()
                }
                if let peer {
                    let _ = self.resolved.modify { current in
                        var current = current
                        current[name] = peer
                        return current
                    }
                }
                return .single(peer)
            }
            |> take(1)
        }
        return combineLatest(signals)
        |> map { peers in peers.compactMap { $0 } }
    }

    // MARK: - Look

    static let gradientColors: [UIColor] = [
        UIColor(red: 0.23, green: 0.33, blue: 1.0, alpha: 1.0),
        UIColor(red: 0.27, green: 0.80, blue: 1.0, alpha: 1.0)
    ]

    /// Cuts the light figure out of an avatar (a white mark on a colored circle) and fills it with the
    /// assistant gradient. The circle becomes transparent, details drawn in the circle's color (eyes) stay cut out.
    static func gradientMark(from avatar: UIImage, size: CGSize) -> UIImage? {
        guard let source = avatar.cgImage else {
            return nil
        }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Mask: how white each pixel is. The circle's darkest channel stays well below the mark's.
        var mask = [UInt8](repeating: 0, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                let alpha = Double(pixels[i + 3]) / 255.0
                guard alpha > 0.0 else { continue }
                let darkest = Double(min(pixels[i], pixels[i + 1], pixels[i + 2])) / 255.0 / alpha
                let value = max(0.0, min(1.0, (darkest - 0.55) / 0.35)) * alpha
                let byte = UInt8(value * 255.0)
                mask[y * width + x] = byte
                if byte > 40 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY else {
            return nil
        }

        // Eyes: holes inside the figure, the part of the circle's color the outside can't reach.
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0 ..< width { stack.append(x); stack.append((height - 1) * width + x) }
        for y in 0 ..< height { stack.append(y * width); stack.append(y * width + width - 1) }
        while let i = stack.popLast() {
            if outside[i] || mask[i] >= 128 { continue }
            outside[i] = true
            let x = i % width, y = i / width
            if x > 0 { stack.append(i - 1) }
            if x < width - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - width) }
            if y < height - 1 { stack.append(i + width) }
        }
        var eyes = [UInt8](repeating: 0, count: width * height)
        for i in 0 ..< width * height where !outside[i] {
            eyes[i] = 255 &- mask[i]
        }
        guard let maskProvider = CGDataProvider(data: Data(mask) as CFData),
              let maskImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: maskProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }

        // Fit the figure (not the circle) into the icon.
        let figure = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let scale = min(size.width / figure.width, size.height / figure.height)
        let drawRect = CGRect(
            x: (size.width - figure.width * scale) / 2.0 - figure.minX * scale,
            y: (size.height - figure.height * scale) / 2.0 - figure.minY * scale,
            width: CGFloat(width) * scale,
            height: CGFloat(height) * scale
        )
        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            let cgContext = rendererContext.cgContext
            // UIKit's context is flipped relative to CGImage rows.
            cgContext.translateBy(x: 0.0, y: size.height)
            cgContext.scaleBy(x: 1.0, y: -1.0)
            let flipped = CGRect(x: drawRect.minX, y: size.height - drawRect.maxY, width: drawRect.width, height: drawRect.height)
            // A grayscale image clips like alpha: white paints, black is cut out.
            cgContext.clip(to: flipped, mask: maskImage)
            let colors = self.gradientColors.map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: size.height), end: CGPoint(x: size.width, y: 0.0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            cgContext.resetClip()
            if let eyesProvider = CGDataProvider(data: Data(eyes) as CFData),
               let eyesImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: eyesProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                cgContext.clip(to: flipped, mask: eyesImage)
                cgContext.setFillColor(UIColor.white.cgColor)
                cgContext.fill(CGRect(origin: .zero, size: size))
            }
        }
    }

    /// The "AI" pill shown next to an assistant in the mention list.
    static let badgeImage: UIImage = {
        let text = NSAttributedString(string: "AI", attributes: [
            .font: UIFont.systemFont(ofSize: 11.0, weight: .bold),
            .foregroundColor: UIColor.white
        ])
        let textSize = text.size()
        let size = CGSize(width: ceil(textSize.width) + 12.0, height: 18.0)
        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            let cgContext = rendererContext.cgContext
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2.0).addClip()
            let colors = [UIColor(red: 0.23, green: 0.33, blue: 1.0, alpha: 1.0).cgColor, UIColor(red: 0.27, green: 0.80, blue: 1.0, alpha: 1.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2.0, y: (size.height - textSize.height) / 2.0))
        }
    }()
}

// MARK: - Header button

import AsyncDisplayKit
import AvatarNode
import TelegramPresentationData

/// The assistant's mark in the group header, next to the group avatar: the figure from the bot's avatar,
/// filled with a gradient, without the avatar's circle.
final class MiraAssistantNavigationButtonNode: HighlightableButtonNode {
    private static let iconSize = CGSize(width: 30.0, height: 30.0)
    private static var cachedIcon: UIImage?

    private let iconNode: ASImageNode
    private var disposable: Disposable?

    init(context: AccountContext, theme: PresentationTheme) {
        self.iconNode = ASImageNode()
        self.iconNode.isUserInteractionEnabled = false
        self.iconNode.displaysAsynchronously = false
        self.iconNode.image = Self.cachedIcon
        super.init()
        self.addSubnode(self.iconNode)
        self.frame = CGRect(origin: .zero, size: CGSize(width: 44.0, height: 44.0))
        self.iconNode.frame = CGRect(x: (44.0 - Self.iconSize.width) / 2.0, y: (44.0 - Self.iconSize.height) / 2.0, width: Self.iconSize.width, height: Self.iconSize.height)
        self.accessibilityLabel = "AI assistant"

        self.disposable = (MiraAssistant.assistantPeers(context: context, matching: "")
        |> mapToSignal { peers -> Signal<UIImage?, NoError> in
            guard let peer = peers.first else {
                return .single(nil)
            }
            return peerAvatarCompleteImage(account: context.account, peer: peer, size: CGSize(width: 120.0, height: 120.0), drawLetters: false)
        }
        |> map { avatar -> UIImage? in
            return avatar.flatMap { MiraAssistant.gradientMark(from: $0, size: MiraAssistantNavigationButtonNode.iconSize) }
        }
        |> deliverOnMainQueue).start(next: { [weak self] icon in
            guard let self, let icon else {
                return
            }
            Self.cachedIcon = icon
            self.iconNode.image = icon
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 44.0, height: 44.0)
    }
}

extension ChatControllerImpl {
    /// Prototype: opens the assistant's private chat in a side panel. The group slides left and stays
    /// visible as a narrow card; tapping it closes the panel.
    func openAssistant() {
        let _ = (MiraAssistant.assistantPeers(context: self.context, matching: "")
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] peers in
            guard let self, let peer = peers.first else {
                return
            }
            self.chatDisplayNode.dismissInput()
            if #available(iOS 17.0, *) {
                let panel = MiraSidePanelController(context: self.context, assistant: peer, groupController: self)
                self.present(panel, in: .window(.root))
            } else {
                self.openPeer(peer: peer, navigation: .chat(textInputState: nil, subject: nil, peekData: nil), fromMessage: nil)
            }
        })
    }
}
