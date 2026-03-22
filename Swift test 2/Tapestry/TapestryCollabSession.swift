import Foundation
import Supabase

// MARK: - StickerOp
//
// A single canvas operation broadcast to all members of a tapestry session.
// Per-op broadcast is what prevents the overwrite bug — each op targets one
// sticker, so two users editing different stickers never conflict.

struct StickerOp: Codable {
    enum OpType: String, Codable {
        case move
        case scale
        case rotate
        case add
        case delete
        case updateText
        case reorder
        case updatePhoto       // background removal or any image replacement
        case updateBackground  // canvas background color or image
    }

    let type:      OpType
    let stickerID: UUID
    let senderID:  UUID   // filtered out on receive so you don't apply your own ops

    // move
    var x: Double?
    var y: Double?

    // scale
    var scale: Double?

    // rotate
    var rotationRadians: Double?

    // add — full sticker state so the receiver can reconstruct it
    var sticker: StickerState?

    // reorder
    var zIndex: Double?

    // updatePhoto — imageURL of the replacement image in Supabase Storage
    var imageURL: String?
    // updatePhoto — monotonically increasing generation; receiver discards older arrivals
    var photoGeneration: Int?

    // updateBackground — set canvas background to a color or remote image
    var bgColorComponents: [Double]?   // [r, g, b, a] in 0-1 range

    // updateText — mirrors StickerState text fields
    var textString:    String?
    var fontIndex:     Int?
    var colorIndex:    Int?
    var textWrapWidth: Double?
    var textAlignment: Int?
    var textBGStyle:   Int?
}

// MARK: - TapestryCollabSession

@Observable
final class TapestryCollabSession {

    // MARK: Public state

    /// True while the Realtime channel is subscribed and ops are being exchanged.
    /// saveCanvas() checks this to skip the full snapshot write during live sessions.
    private(set) var isActive = false

    /// StickerCanvasView sets this closure to receive and apply incoming ops.
    var onOpReceived: ((StickerOp) -> Void)?

    /// Called when the owner deletes the tapestry while this member is inside the canvas.
    var onTapestryDeleted: (() -> Void)?

    // MARK: Identity

    /// The tapestry this session is for.
    let tapestryID: UUID

    /// The current user's ID — used to filter out echoed ops.
    let senderID: UUID

    // MARK: Private

    private var channel: RealtimeChannelV2?
    private var listenerTask: Task<Void, Never>?

    // MARK: Init

    init(tapestryID: UUID, senderID: UUID) {
        self.tapestryID = tapestryID
        self.senderID   = senderID
    }

    // MARK: - Lifecycle

    func start() async {
        let ch = await supabase.realtimeV2.channel("tapestry:\(tapestryID.uuidString)")
        channel = ch

        // Listen for incoming sticker ops
        listenerTask = Task { [weak self] in
            guard let self else { return }
            for await message in await ch.broadcastStream(event: "sticker-op") {
                // Supabase wraps the broadcast in {"type":"broadcast","event":"...","payload":{...}}
                // We must extract the inner "payload" before decoding as StickerOp.
                guard
                    case .object(let inner) = message["payload"],
                    let data = try? JSONEncoder().encode(inner),
                    let op   = try? JSONDecoder().decode(StickerOp.self, from: data),
                    op.senderID != self.senderID   // ignore our own echoed broadcasts
                else { continue }

                await MainActor.run { self.onOpReceived?(op) }
            }
        }

        // Listen for owner-initiated tapestry deletion
        Task { [weak self] in
            guard let self else { return }
            for await _ in await ch.broadcastStream(event: "tapestry-deleted") {
                await MainActor.run { self.onTapestryDeleted?() }
            }
        }

        await ch.subscribe()
        await MainActor.run { isActive = true }
    }

    func end() async {
        listenerTask?.cancel()
        listenerTask = nil
        await channel?.unsubscribe()
        channel = nil
        await MainActor.run { isActive = false }
    }

    // MARK: - Broadcast

    /// Send a sticker operation to all other members of this tapestry.
    /// Called from StickerCanvasView gesture callbacks — fire and forget.
    func broadcast(_ op: StickerOp) {
        guard let channel else { return }
        Task {
            do {
                try await channel.broadcast(event: "sticker-op", message: op)
            } catch {
                print("TapestryCollabSession: broadcast failed — \(error)")
            }
        }
    }

    // MARK: - Convenience op builders

    func opMove(stickerID: UUID, x: Double, y: Double) -> StickerOp {
        StickerOp(type: .move, stickerID: stickerID, senderID: senderID, x: x, y: y)
    }

    func opScale(stickerID: UUID, scale: Double) -> StickerOp {
        StickerOp(type: .scale, stickerID: stickerID, senderID: senderID, scale: scale)
    }

    func opRotate(stickerID: UUID, radians: Double) -> StickerOp {
        StickerOp(type: .rotate, stickerID: stickerID, senderID: senderID, rotationRadians: radians)
    }

    func opAdd(sticker: StickerState) -> StickerOp {
        StickerOp(type: .add, stickerID: sticker.id, senderID: senderID, sticker: sticker)
    }

    func opDelete(stickerID: UUID) -> StickerOp {
        StickerOp(type: .delete, stickerID: stickerID, senderID: senderID)
    }

    func opReorder(stickerID: UUID, zIndex: Double) -> StickerOp {
        StickerOp(type: .reorder, stickerID: stickerID, senderID: senderID, zIndex: zIndex)
    }

    func opUpdatePhoto(stickerID: UUID, imageURL: String, generation: Int = 0) -> StickerOp {
        StickerOp(type: .updatePhoto, stickerID: stickerID, senderID: senderID,
                  imageURL: imageURL, photoGeneration: generation)
    }

    func opUpdateBackground(colorComponents: [Double]) -> StickerOp {
        StickerOp(type: .updateBackground, stickerID: tapestryID, senderID: senderID,
                  bgColorComponents: colorComponents)
    }

    func opUpdateBackground(imageURL: String) -> StickerOp {
        StickerOp(type: .updateBackground, stickerID: tapestryID, senderID: senderID,
                  imageURL: imageURL)
    }

    func opUpdateText(stickerID: UUID, content: TextStickerContent) -> StickerOp {
        StickerOp(
            type: .updateText, stickerID: stickerID, senderID: senderID,
            textString: content.text,
            fontIndex: content.fontIndex,
            colorIndex: content.colorIndex,
            textWrapWidth: Double(content.wrapWidth),
            textAlignment: content.alignment,
            textBGStyle: content.bgStyle
        )
    }
}
