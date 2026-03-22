import Foundation
import Observation
import SwiftUI
import UIKit
import Supabase

// MARK: - Broadcast payloads

// File-scope so it satisfies the Sendable requirement of channel.broadcast.
struct TapestryDeletionMsg: Codable, Sendable {
    let senderID: String
}

// MARK: - Supabase row shapes

private struct TapestryMemberRow: Decodable {
    let tapestryID: UUID
    enum CodingKeys: String, CodingKey { case tapestryID = "tapestry_id" }
}

// MARK: - Supabase update payloads

private struct CanvasUpdate: Encodable {
    let canvas_data: String
    let updated_at:  String
}

private struct TitleUpdate: Encodable {
    let title: String
}

private struct ThumbUpdate: Encodable {
    let thumbnail_url: String
}

private struct ModeUpdate: Encodable {
    let canvas_mode: String
}

private struct CoverShapeUpdate: Encodable {
    let cover_shape: String
}

private struct DisplayOrderUpdate: Encodable {
    let display_order: Int
}

private struct PinnedUpdate: Encodable {
    let is_pinned: Bool
}

/// What we send to Supabase on insert
private struct TapestryInsert: Encodable {
    let id: UUID
    let ownerID: UUID
    let title: String
    let description: String
    let type: String
    let canvasMode: String

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID      = "owner_id"
        case title
        case description
        case type
        case canvasMode   = "canvas_mode"
    }
}

/// What we receive back from Supabase on select.
/// Dates are decoded as raw strings to avoid JSONDecoder ISO-8601 format mismatches
/// (Supabase returns "2024-01-15T10:30:00.123456+00:00" which the default decoder rejects).
private struct TapestryRow: Decodable {
    let id: UUID
    let ownerID: UUID
    let title: String
    let description: String
    let type: String
    let createdAt: String
    let updatedAt: String
    let canvasData: String?
    let canvasMode: String?      // nil for rows created before the column was added → defaults to .infinite
    let thumbnailURL: String?    // nil if cover not yet uploaded
    let coverShape: String?      // nil for rows before this column was added → defaults to .square
    let displayOrder: Int?       // nil for rows before this column was added → defaults to 0
    let isPinned: Bool?          // nil for rows before this column was added → defaults to false

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID      = "owner_id"
        case title
        case description
        case type
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
        case canvasData   = "canvas_data"
        case canvasMode   = "canvas_mode"
        case thumbnailURL = "thumbnail_url"
        case coverShape   = "cover_shape"
        case displayOrder = "display_order"
        case isPinned     = "is_pinned"
    }

    func toTapestry() -> Tapestry {
        Tapestry(
            id: id,
            title: title,
            description: description,
            thumbnailFilename: nil,
            thumbnailURL: thumbnailURL,
            createdAt: Self.parseDate(createdAt),
            updatedAt: Self.parseDate(updatedAt),
            type: TapestryType(rawValue: type) ?? .personal,
            canvasData: canvasData,
            ownerID: ownerID,
            canvasMode: canvasMode.flatMap { CanvasMode(rawValue: $0) } ?? .infinite,
            coverShape: coverShape.flatMap { CoverShape(rawValue: $0) } ?? .square,
            displayOrder: displayOrder ?? 0,
            isPinned: isPinned ?? false
        )
    }

    static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ string: String) -> Date {
        isoFull.date(from: string) ?? isoBasic.date(from: string) ?? Date()
    }
}

// MARK: - TapestryStore

@Observable
final class TapestryStore {
    private(set) var tapestries: [Tapestry] = []

    // User-defined display order (local, not synced to Supabase)
    private(set) var tapestryOrder: [UUID] = []

    // Set when user signs in so add/delete can attach owner_id
    var currentUserID: UUID?

    private static let thumbDir  = "tapestry-thumbs"
    private static let thumbsKey = "tapestry_thumbnail_filenames"
    private static let orderKey  = "tapestry_display_order"

    // Thumbnail cache — observable so writes immediately re-render any subscribed view
    private var thumbnailCache: [UUID: UIImage] = [:]

    // Persisted map of tapestryID → thumbnail filename
    private var savedThumbnailMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.thumbsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.thumbsKey) }
    }

    private var thumbsDir: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.thumbDir)
    }

    init() { loadDisplayOrder() }

    // MARK: - Display Order

    private func loadDisplayOrder() {
        tapestryOrder = (UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? [])
            .compactMap(UUID.init)
    }

    private func saveDisplayOrder() {
        UserDefaults.standard.set(tapestryOrder.map(\.uuidString), forKey: Self.orderKey)
    }

    /// Returns unpinned tapestries in the user's custom display order.
    /// Tapestries not yet in the order (newly added from another device) appear first.
    func orderedUnpinnedTapestries(excludingPinnedID pinnedID: UUID?) -> [Tapestry] {
        let base = tapestries.filter { $0.id != pinnedID }
        var placed = Set<UUID>()
        var ordered: [Tapestry] = []
        for id in tapestryOrder {
            if let t = base.first(where: { $0.id == id }) {
                ordered.append(t)
                placed.insert(id)
            }
        }
        // Prepend any not yet in the order (new items)
        let unordered = base.filter { !placed.contains($0.id) }
        return unordered + ordered
    }

    /// Moves a tapestry within the display order.
    func moveTapestry(fromOffsets: IndexSet, toOffset: Int, excludingPinnedID pinnedID: UUID?) {
        var ordered = orderedUnpinnedTapestries(excludingPinnedID: pinnedID)
        ordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        tapestryOrder = ordered.map(\.id)
        saveDisplayOrder()
    }

    /// Replaces the display order with the given already-ordered unpinned tapestries.
    func setDisplayOrder(to ordered: [Tapestry]) {
        tapestryOrder = ordered.map(\.id)
        saveDisplayOrder()
        // Update displayOrder on each tapestry in-memory and sync to Supabase
        for (index, tapestry) in ordered.enumerated() {
            if let i = tapestries.firstIndex(where: { $0.id == tapestry.id }) {
                tapestries[i].displayOrder = index
            }
        }
        Task {
            for (index, tapestry) in ordered.enumerated() {
                try? await supabase
                    .from("tapestries")
                    .update(DisplayOrderUpdate(display_order: index))
                    .eq("id", value: tapestry.id.uuidString)
                    .execute()
            }
        }
    }

    // MARK: - Fetch from Supabase

    func fetch() async {
        guard let uid = currentUserID else { return }
        do {
            // 1. Tapestries the user owns
            let owned: [TapestryRow] = try await supabase
                .from("tapestries")
                .select()
                .eq("owner_id", value: uid.uuidString)
                .order("updated_at", ascending: false)
                .execute()
                .value

            // 2. Tapestries the user joined via invite
            let memberLinks: [TapestryMemberRow] = try await supabase
                .from("tapestry_members")
                .select("tapestry_id")
                .eq("user_id", value: uid.uuidString)
                .execute()
                .value

            var joined: [TapestryRow] = []
            if !memberLinks.isEmpty {
                let ids = memberLinks.map { $0.tapestryID.uuidString }
                joined = try await supabase
                    .from("tapestries")
                    .select()
                    .in("id", values: ids)
                    .order("updated_at", ascending: false)
                    .execute()
                    .value
            }

            // Merge — owned first, then joined (skip duplicates)
            var seen = Set<UUID>()
            var all: [TapestryRow] = []
            for row in owned + joined {
                if seen.insert(row.id).inserted { all.append(row) }
            }

            await MainActor.run {
                let thumbMap = savedThumbnailMap
                let dir = thumbsDir
                tapestries = all.map { row in
                    var t = row.toTapestry()
                    let localFilename = thumbMap[row.id.uuidString]
                    t.thumbnailFilename = localFilename
                    // If the local file no longer exists but we have a remote URL, clear
                    // the stale filename so thumbnail(for:) falls through to downloadThumbnail.
                    if let fn = localFilename,
                       !FileManager.default.fileExists(atPath: dir.appendingPathComponent(fn).path) {
                        t.thumbnailFilename = nil
                    }
                    return t
                }
                let activeIDs = Set(tapestries.map(\.id))
                tapestryOrder = tapestryOrder.filter { activeIDs.contains($0) }
                // If local order is empty (e.g. new device / reinstall), seed it from server displayOrder
                if tapestryOrder.isEmpty {
                    let serverOrdered = tapestries.sorted { $0.displayOrder < $1.displayOrder }
                    tapestryOrder = serverOrdered.map(\.id)
                }
                saveDisplayOrder()
            }
        } catch {
            print("TapestryStore.fetch error: \(error)")
        }
    }

    // MARK: - CRUD

    func add(_ tapestry: Tapestry) {
        tapestries.insert(tapestry, at: 0)
        tapestryOrder.insert(tapestry.id, at: 0)  // keep new item at the front
        saveDisplayOrder()
        guard let uid = currentUserID else { return }
        Task {
            do {
                try await supabase
                    .from("tapestries")
                    .insert(TapestryInsert(
                        id: tapestry.id,
                        ownerID: uid,
                        title: tapestry.title,
                        description: tapestry.description,
                        type: tapestry.type.rawValue,
                        canvasMode: tapestry.canvasMode.rawValue
                    ))
                    .execute()
            } catch {
                print("TapestryStore.add error: \(error)")
            }
        }
    }

    func clear() {
        tapestries = []
    }

    func updateCanvas(tapestryID: UUID, canvasJSON: String) {
        let now = Date()
        // Immediate local update + re-sort so most-recently-edited bubble moves first
        if let i = tapestries.firstIndex(where: { $0.id == tapestryID }) {
            tapestries[i].canvasData = canvasJSON
            tapestries[i].updatedAt  = now
        }

        Task {
            do {
                try await supabase
                    .from("tapestries")
                    .update(CanvasUpdate(canvas_data: canvasJSON,
                                        updated_at: TapestryRow.isoFull.string(from: now)))
                    .eq("id", value: tapestryID.uuidString)
                    .execute()
            } catch {
                print("TapestryStore.updateCanvas error: \(error)")
            }
        }
    }

    func rename(_ tapestry: Tapestry, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let idx = tapestries.firstIndex(where: { $0.id == tapestry.id }) {
            tapestries[idx].title = trimmed
        }
        Task {
            do {
                try await supabase
                    .from("tapestries")
                    .update(TitleUpdate(title: trimmed))
                    .eq("id", value: tapestry.id.uuidString)
                    .execute()
            } catch {
                print("TapestryStore.rename error: \(error)")
            }
        }
    }

    func delete(_ tapestry: Tapestry) {
        tapestries.removeAll { $0.id == tapestry.id }
        tapestryOrder.removeAll { $0 == tapestry.id }
        saveDisplayOrder()
        thumbnailCache.removeValue(forKey: tapestry.id)
        if let fn = tapestry.thumbnailFilename {
            try? FileManager.default.removeItem(at: thumbsDir.appendingPathComponent(fn))
        }
        var map = savedThumbnailMap
        map.removeValue(forKey: tapestry.id.uuidString)
        savedThumbnailMap = map
        guard let uid = currentUserID else { return }
        Task {
            do {
                // Notify members currently inside the canvas before deleting
                let ch = await supabase.realtimeV2.channel("tapestry:\(tapestry.id.uuidString)")
                await ch.subscribe()
                try? await ch.broadcast(event: "tapestry-deleted",
                                        message: TapestryDeletionMsg(senderID: uid.uuidString))
                try? await Task.sleep(for: .milliseconds(600))
                await ch.unsubscribe()

                try await supabase
                    .from("tapestries")
                    .delete()
                    .eq("id", value: tapestry.id.uuidString)
                    .execute()
            } catch {
                print("TapestryStore.delete error: \(error)")
            }
        }
    }

    /// Removes the current user from a group tapestry they were invited to.
    /// Does NOT delete the tapestry itself — other members are unaffected.
    func leaveTapestry(_ tapestry: Tapestry) {
        tapestries.removeAll { $0.id == tapestry.id }
        tapestryOrder.removeAll { $0 == tapestry.id }
        saveDisplayOrder()
        thumbnailCache.removeValue(forKey: tapestry.id)
        if let fn = tapestry.thumbnailFilename {
            try? FileManager.default.removeItem(at: thumbsDir.appendingPathComponent(fn))
        }
        var map = savedThumbnailMap
        map.removeValue(forKey: tapestry.id.uuidString)
        savedThumbnailMap = map
        guard let uid = currentUserID else { return }
        Task {
            do {
                try await supabase
                    .from("tapestry_members")
                    .delete()
                    .eq("tapestry_id", value: tapestry.id.uuidString)
                    .eq("user_id", value: uid.uuidString)
                    .execute()
            } catch {
                print("TapestryStore.leaveTapestry error: \(error)")
            }
        }
    }

    // MARK: - Thumbnail helpers

    func saveThumbnail(_ image: UIImage, for tapestryID: UUID) -> String? {
        thumbnailCache[tapestryID] = image          // cache immediately in memory
        let dir = thumbsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(tapestryID.uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        let fileURL = dir.appendingPathComponent(filename)
        try? data.write(to: fileURL)

        // Upload to Supabase Storage in the background so the cover survives reinstall
        Task.detached(priority: .utility) { [weak self] in
            let path = "thumbnails/\(tapestryID.uuidString).jpg"
            do {
                try await supabase.storage
                    .from("sticker-assets")
                    .upload(path, data: data,
                            options: .init(contentType: "image/jpeg", upsert: true))
                let remoteURL = try supabase.storage
                    .from("sticker-assets")
                    .getPublicURL(path: path)
                    .absoluteString
                try await supabase
                    .from("tapestries")
                    .update(ThumbUpdate(thumbnail_url: remoteURL))
                    .eq("id", value: tapestryID.uuidString)
                    .execute()
                await MainActor.run {
                    if let i = self?.tapestries.firstIndex(where: { $0.id == tapestryID }) {
                        self?.tapestries[i].thumbnailURL = remoteURL
                    }
                }
            } catch {
                print("[TapestryStore] thumbnail upload error: \(error)")
            }
        }

        return filename
    }

    func thumbnail(for tapestry: Tapestry) -> UIImage? {
        // Serve from memory cache — zero disk I/O on subsequent calls
        if let cached = thumbnailCache[tapestry.id] { return cached }

        // Try local disk
        if let fn = tapestry.thumbnailFilename {
            let url = thumbsDir.appendingPathComponent(fn)
            if let img = UIImage(contentsOfFile: url.path) {
                thumbnailCache[tapestry.id] = img
                return img
            }
        }

        // Local file missing — download from remote URL if we have one
        if let urlString = tapestry.thumbnailURL {
            downloadThumbnail(tapestryID: tapestry.id, urlString: urlString)
        }
        return nil
    }

    private func downloadThumbnail(tapestryID: UUID, urlString: String) {
        // Skip if already downloading or already cached
        guard thumbnailCache[tapestryID] == nil else { return }
        guard let url = URL(string: urlString) else { return }
        let dir = thumbsDir   // capture before going off MainActor
        Task.detached(priority: .utility) { [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let img = UIImage(data: data) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let filename = "\(tapestryID.uuidString).jpg"
            try? data.write(to: dir.appendingPathComponent(filename))
            await MainActor.run {
                self?.thumbnailCache[tapestryID] = img
                self?.updateThumbnailFilename(tapestryID: tapestryID, filename: filename)
            }
        }
    }

    func updateThumbnailFilename(tapestryID: UUID, filename: String) {
        if let i = tapestries.firstIndex(where: { $0.id == tapestryID }) {
            tapestries[i].thumbnailFilename = filename
        }
        var map = savedThumbnailMap
        map[tapestryID.uuidString] = filename
        savedThumbnailMap = map
    }

    // MARK: - Canvas Mode

    func canvasMode(for tapestryID: UUID) -> CanvasMode {
        // Prefer the value stored on the Tapestry itself (sourced from Supabase),
        // so all members of a shared tapestry see the same canvas mode.
        tapestries.first(where: { $0.id == tapestryID })?.canvasMode ?? .infinite
    }

    func setCanvasMode(tapestryID: UUID, mode: CanvasMode) {
        // Update in-memory model immediately
        if let i = tapestries.firstIndex(where: { $0.id == tapestryID }) {
            tapestries[i].canvasMode = mode
        }
        // Persist to Supabase so joining members get the correct mode
        Task {
            try? await supabase
                .from("tapestries")
                .update(ModeUpdate(canvas_mode: mode.rawValue))
                .eq("id", value: tapestryID.uuidString)
                .execute()
        }
    }

    // MARK: - Cover Shape

    func coverShape(for tapestryID: UUID) -> CoverShape {
        tapestries.first(where: { $0.id == tapestryID })?.coverShape ?? .square
    }

    func setCoverShape(tapestryID: UUID, shape: CoverShape) {
        if let i = tapestries.firstIndex(where: { $0.id == tapestryID }) {
            tapestries[i].coverShape = shape
        }
        Task {
            try? await supabase
                .from("tapestries")
                .update(CoverShapeUpdate(cover_shape: shape.rawValue))
                .eq("id", value: tapestryID.uuidString)
                .execute()
        }
    }

    // MARK: - Pinned Tapestry

    var pinnedTapestry: Tapestry? {
        tapestries.first(where: { $0.isPinned })
    }

    func setPinned(tapestryID: UUID?) {
        // Update in-memory model
        for i in tapestries.indices {
            tapestries[i].isPinned = (tapestries[i].id == tapestryID)
        }
        // Sync to Supabase
        Task {
            // Clear all pinned first, then set the new one
            try? await supabase
                .from("tapestries")
                .update(PinnedUpdate(is_pinned: false))
                .eq("owner_id", value: currentUserID?.uuidString ?? "")
                .execute()
            if let tid = tapestryID {
                try? await supabase
                    .from("tapestries")
                    .update(PinnedUpdate(is_pinned: true))
                    .eq("id", value: tid.uuidString)
                    .execute()
            }
        }
    }
}
