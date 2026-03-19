import SwiftUI

// MARK: - Accent colour helper (used by TapestryGridView and ProfileView's pinned card)

private let tapestryAccentPalette: [Color] = [
    Color(red: 0.95, green: 0.60, blue: 0.55),
    Color(red: 0.55, green: 0.75, blue: 0.95),
    Color(red: 0.75, green: 0.90, blue: 0.65),
    Color(red: 0.95, green: 0.80, blue: 0.50),
    Color(red: 0.80, green: 0.65, blue: 0.95),
    Color(red: 0.55, green: 0.90, blue: 0.85),
    Color(red: 0.95, green: 0.70, blue: 0.85),
]

func tapestryAccentColor(for tapestry: Tapestry) -> Color {
    tapestryAccentPalette[abs(tapestry.title.hashValue) % tapestryAccentPalette.count]
}

// MARK: - LayoutSection

/// Describes how tapestries are grouped into visual rows.
private enum LayoutSection: Identifiable {
    case wide(Tapestry)                      // spans full row
    case pair(Tapestry, Tapestry)            // two squares side by side
    case single(Tapestry)                    // one square, left-aligned
    case tallLeft(Tapestry, [Tapestry])      // tall on left,  ≤2 squares on right
    case tallRight([Tapestry], Tapestry)     // ≤2 squares on left, tall on right

    var id: UUID {
        switch self {
        case .wide(let t):          return t.id
        case .pair(let t, _):       return t.id
        case .single(let t):        return t.id
        case .tallLeft(let t, _):   return t.id
        case .tallRight(let sq, _): return sq[0].id
        }
    }
}

// MARK: - TapestryGridView

struct TapestryGridView: View {
    /// The ordered list of tapestries to display (excluding pinned, if any).
    let tapestries: [Tapestry]

    @Binding var pinnedTapestryIDStr: String
    @Binding var coverPickTapestry:   Tapestry?
    @Binding var coverPickAspectRatio: CGFloat

    let onSelect: (Tapestry) -> Void

    @Environment(TapestryStore.self) private var store

    // Grid layout state
    @State private var isEditingLayout = false
    @State private var draggingID:   UUID?   = nil
    @State private var previewOrder: [UUID]  = []
    @State private var gridWidth: CGFloat    = UIScreen.main.bounds.width - 32

    // Alert state (owned here so ProfileView doesn't need to know about it)
    @State private var tapestryToDelete: Tapestry? = nil
    @State private var tapestryToLeave:  Tapestry? = nil
    @State private var tapestryToRename: Tapestry? = nil
    @State private var renameText: String = ""

    // MARK: - Layout metrics

    private var cellWidth: CGFloat      { (gridWidth - 12) / 2 }
    private var tallCellHeight: CGFloat { cellWidth * 2 + 36 }  // 18pt gap + 18pt title row

    // MARK: - Body

    var body: some View {
        let sections = buildLayout(displayedTapestries)

        VStack(spacing: 0) {
            // Header row
            HStack {
                Text("TAPESTRIES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                if isEditingLayout {
                    Button("Done") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if !previewOrder.isEmpty {
                                let byID = Dictionary(uniqueKeysWithValues: tapestries.map { ($0.id, $0) })
                                let ordered = previewOrder.compactMap { byID[$0] }
                                store.setDisplayOrder(to: ordered)
                            }
                            isEditingLayout = false
                            draggingID      = nil
                            previewOrder    = []
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Cell grid
            VStack(spacing: 12) {
                ForEach(sections) { section in
                    sectionView(section, cellW: cellWidth, tallH: tallCellHeight)
                }
            }
            .coordinateSpace(name: "tapestryGrid")
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: previewOrder)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { gridWidth = geo.size.width - 32 }
                    .onChange(of: geo.size.width) { _, w in gridWidth = w - 32 }
            }
        )
        // Alerts live here so ProfileView stays clean
        .confirmationDialog(
            tapestryToDelete.map { "Delete \"\($0.title)\"?" } ?? "",
            isPresented: Binding(
                get: { tapestryToDelete != nil },
                set: { if !$0 { tapestryToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let t = tapestryToDelete { withAnimation { store.delete(t) } }
                tapestryToDelete = nil
            }
            Button("Cancel", role: .cancel) { tapestryToDelete = nil }
        }
        .alert(
            "Remove from your profile?",
            isPresented: Binding(
                get: { tapestryToLeave != nil },
                set: { if !$0 { tapestryToLeave = nil } }
            ),
            presenting: tapestryToLeave
        ) { tapestry in
            Button("Remove", role: .destructive) {
                withAnimation { store.leaveTapestry(tapestry) }
                tapestryToLeave = nil
            }
            Button("Cancel", role: .cancel) { tapestryToLeave = nil }
        } message: { tapestry in
            Text("This removes \"\(tapestry.title)\" from your profile. Other members will still have access and the tapestry will not be deleted.")
        }
        .alert("Rename Tapestry", isPresented: Binding(
            get: { tapestryToRename != nil },
            set: { if !$0 { tapestryToRename = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let t = tapestryToRename { store.rename(t, to: renameText) }
                tapestryToRename = nil
            }
            Button("Cancel", role: .cancel) { tapestryToRename = nil }
        } message: {
            Text("Enter a new name for this tapestry.")
        }
    }

    // MARK: - Display order

    private var displayedTapestries: [Tapestry] {
        guard draggingID != nil, !previewOrder.isEmpty else { return tapestries }
        let byID = Dictionary(uniqueKeysWithValues: tapestries.map { ($0.id, $0) })
        return previewOrder.compactMap { byID[$0] }
    }

    // MARK: - Layout builder

    private func buildLayout(_ taps: [Tapestry]) -> [LayoutSection] {
        var result: [LayoutSection] = []
        var i = 0
        while i < taps.count {
            let t         = taps[i]
            let shape     = store.coverShape(for: t.id)
            let isDragged = draggingID == t.id

            switch shape {
            case .wide:
                result.append(.wide(t)); i += 1

            case .tall:
                if isDragged {
                    result.append(.tallLeft(t, [])); i += 1
                } else {
                    var right: [Tapestry] = []
                    var j = i + 1
                    while j < taps.count, right.count < 2,
                          store.coverShape(for: taps[j].id) == .square,
                          taps[j].id != draggingID {
                        right.append(taps[j]); j += 1
                    }
                    result.append(.tallLeft(t, right)); i = j
                }

            case .square:
                if isDragged {
                    result.append(.single(t)); i += 1
                } else if i + 1 < taps.count,
                          taps[i + 1].id != draggingID,
                          store.coverShape(for: taps[i + 1].id) == .tall {
                    let tall = taps[i + 1]
                    if i + 2 < taps.count,
                       taps[i + 2].id != draggingID,
                       store.coverShape(for: taps[i + 2].id) == .square {
                        result.append(.tallRight([t, taps[i + 2]], tall)); i += 3
                    } else {
                        result.append(.tallRight([t], tall)); i += 2
                    }
                } else if i + 1 < taps.count,
                          store.coverShape(for: taps[i + 1].id) == .square,
                          taps[i + 1].id != draggingID {
                    result.append(.pair(t, taps[i + 1])); i += 2
                } else {
                    result.append(.single(t)); i += 1
                }
            }
        }
        return result
    }

    // MARK: - Section view

    @ViewBuilder
    private func sectionView(_ section: LayoutSection, cellW: CGFloat, tallH: CGFloat) -> some View {
        switch section {
        case .wide(let t):
            coverCell(t, width: gridWidth, height: cellW)
        case .pair(let t1, let t2):
            HStack(alignment: .top, spacing: 12) {
                coverCell(t1, width: cellW, height: cellW)
                coverCell(t2, width: cellW, height: cellW)
            }
        case .single(let t):
            HStack(spacing: 0) {
                coverCell(t, width: cellW, height: cellW)
                Spacer()
            }
        case .tallLeft(let tall, let rights):
            HStack(alignment: .top, spacing: 12) {
                coverCell(tall, width: cellW, height: tallH)
                VStack(spacing: 12) {
                    ForEach(rights) { t in coverCell(t, width: cellW, height: cellW) }
                    if rights.count < 2 {
                        Color.clear.frame(width: cellW, height: rights.isEmpty ? tallH : cellW)
                    }
                }
                .frame(width: cellW, alignment: .top)
            }
        case .tallRight(let lefts, let tall):
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(lefts) { t in coverCell(t, width: cellW, height: cellW) }
                    if lefts.count < 2 {
                        Color.clear.frame(width: cellW, height: lefts.isEmpty ? tallH : cellW)
                    }
                }
                .frame(width: cellW, alignment: .top)
                coverCell(tall, width: cellW, height: tallH)
            }
        }
    }

    // MARK: - Individual cover cell

    @ViewBuilder
    private func coverCell(_ tapestry: Tapestry, width: CGFloat, height: CGFloat) -> some View {
        let isDragging = draggingID == tapestry.id

        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let img = store.thumbnail(for: tapestry) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    let accent = tapestryAccentColor(for: tapestry)
                    LinearGradient(colors: [accent, accent.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: tapestry.type == .group ? "person.3.fill" : "photo.artframe")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isEditingLayout {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.38))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .padding(6)
                }
            }
            .overlay {
                if isEditingLayout { shapeEditOverlay(for: tapestry) }
            }
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)

            HStack(spacing: 4) {
                Text(tapestry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if tapestry.type == .group {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .scaleEffect(isDragging ? 0.94 : 1.0)
        .opacity(isDragging ? 0.55 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isDragging)
        .onTapGesture {
            if isEditingLayout { cycleShape(for: tapestry) } else { onSelect(tapestry) }
        }
        .contextMenu { contextMenuItems(for: tapestry) }
        .simultaneousGesture(when: isEditingLayout,
            LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("tapestryGrid")))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag):
                        if draggingID != tapestry.id {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            draggingID = tapestry.id
                            if previewOrder.isEmpty { previewOrder = tapestries.map(\.id) }
                        }
                        guard let dragVal = drag else { return }
                        let targetIdx = gridTargetIndex(at: dragVal.location, taps: displayedTapestries)
                        guard let fromIdx = previewOrder.firstIndex(of: tapestry.id),
                              targetIdx != fromIdx else { return }
                        var newOrder = previewOrder
                        newOrder.remove(at: fromIdx)
                        newOrder.insert(tapestry.id, at: targetIdx)
                        previewOrder = newOrder
                    default: break
                    }
                }
                .onEnded { value in
                    if case .second(true, _) = value {
                        let byID = Dictionary(uniqueKeysWithValues: tapestries.map { ($0.id, $0) })
                        let ordered = previewOrder.compactMap { byID[$0] }
                        if !ordered.isEmpty { store.setDisplayOrder(to: ordered) }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { draggingID = nil }
                    }
                }
        )
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenuItems(for tapestry: Tapestry) -> some View {
        Button {
            let shape = store.coverShape(for: tapestry.id)
            let cellW = (gridWidth - 12) / 2
            coverPickAspectRatio = switch shape {
            case .square: 1.0
            case .wide:   gridWidth / cellW
            case .tall:   cellW / (cellW * 2 + 36)
            }
            coverPickTapestry = tapestry
        } label: { Label("Edit Cover", systemImage: "crop") }

        Button {
            renameText = tapestry.title
            tapestryToRename = tapestry
        } label: { Label("Rename", systemImage: "pencil") }

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                previewOrder    = tapestries.map(\.id)
                isEditingLayout = true
                draggingID      = nil
            }
        } label: { Label("Edit Layout", systemImage: "square.grid.2x2") }

        Button {
            withAnimation { pinnedTapestryIDStr = tapestry.id.uuidString }
        } label: { Label("Pin to Profile", systemImage: "pin") }

        if tapestry.ownerID == store.currentUserID {
            Button(role: .destructive) {
                tapestryToDelete = tapestry
            } label: { Label("Delete", systemImage: "trash") }
        } else {
            Button(role: .destructive) {
                tapestryToLeave = tapestry
            } label: { Label("Remove", systemImage: "minus.circle") }
        }
    }

    // MARK: - Shape edit overlay

    @ViewBuilder
    private func shapeEditOverlay(for tapestry: Tapestry) -> some View {
        let shape = store.coverShape(for: tapestry.id)
        ZStack {
            Color.black.opacity(0.28)
            VStack {
                Spacer()
                Label(shape.label, systemImage: shape.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func cycleShape(for tapestry: Tapestry) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.setCoverShape(tapestryID: tapestry.id, shape: store.coverShape(for: tapestry.id).next)
        }
    }

    // MARK: - Drag target index

    private func gridTargetIndex(at location: CGPoint, taps: [Tapestry]) -> Int {
        guard !taps.isEmpty else { return 0 }
        let cellW = (gridWidth - 12) / 2
        let gap: CGFloat    = 12
        let titleH: CGFloat = 18
        let cellTotalH = cellW + 6 + titleH

        var centers: [(idx: Int, center: CGPoint)] = []
        var y: CGFloat = 0
        var i = 0

        while i < taps.count {
            let t         = taps[i]
            let shape     = store.coverShape(for: t.id)
            let isDragged = draggingID == t.id

            switch shape {
            case .wide:
                centers.append((i, CGPoint(x: gridWidth / 2, y: y + cellTotalH / 2)))
                y += cellTotalH + gap; i += 1

            case .tall:
                let tallCoverH = cellW * 2 + 18 + titleH
                let tallTotalH = tallCoverH + 6 + titleH
                centers.append((i, CGPoint(x: cellW / 2, y: y + tallTotalH / 2)))
                var rightY = y; var j = i + 1; var rightCount = 0
                let maxRight = isDragged ? 0 : 2
                while j < taps.count, rightCount < maxRight,
                      store.coverShape(for: taps[j].id) == .square,
                      taps[j].id != draggingID {
                    centers.append((j, CGPoint(x: cellW + gap + cellW / 2, y: rightY + cellTotalH / 2)))
                    rightY += cellTotalH + gap; j += 1; rightCount += 1
                }
                y += max(tallTotalH, rightCount > 0 ? rightY - y - gap : tallTotalH) + gap
                i = j

            case .square:
                let tallCoverH2 = cellW * 2 + 18 + titleH
                let tallTotalH2 = tallCoverH2 + 6 + titleH
                if isDragged {
                    centers.append((i, CGPoint(x: cellW / 2, y: y + cellTotalH / 2)))
                    y += cellTotalH + gap; i += 1
                } else if i + 1 < taps.count,
                          taps[i + 1].id != draggingID,
                          store.coverShape(for: taps[i + 1].id) == .tall {
                    centers.append((i,     CGPoint(x: cellW / 2,               y: y + cellTotalH / 2)))
                    centers.append((i + 1, CGPoint(x: cellW + gap + cellW / 2, y: y + tallTotalH2 / 2)))
                    if i + 2 < taps.count,
                       taps[i + 2].id != draggingID,
                       store.coverShape(for: taps[i + 2].id) == .square {
                        centers.append((i + 2, CGPoint(x: cellW / 2, y: y + cellTotalH + gap + cellTotalH / 2)))
                        y += max(tallTotalH2, 2 * cellTotalH + gap) + gap; i += 3
                    } else {
                        y += max(tallTotalH2, cellTotalH) + gap; i += 2
                    }
                } else if i + 1 < taps.count,
                          store.coverShape(for: taps[i + 1].id) == .square,
                          taps[i + 1].id != draggingID {
                    centers.append((i,     CGPoint(x: cellW / 2,               y: y + cellTotalH / 2)))
                    centers.append((i + 1, CGPoint(x: cellW + gap + cellW / 2, y: y + cellTotalH / 2)))
                    y += cellTotalH + gap; i += 2
                } else {
                    centers.append((i, CGPoint(x: cellW / 2, y: y + cellTotalH / 2)))
                    y += cellTotalH + gap; i += 1
                }
            }
        }

        var bestIdx = 0; var bestDist = CGFloat.infinity
        for (arrayIdx, center) in centers {
            let d = (location.x - center.x) * (location.x - center.x) +
                    (location.y - center.y) * (location.y - center.y)
            if d < bestDist { bestDist = d; bestIdx = arrayIdx }
        }
        return min(max(0, taps.count - 1), bestIdx)
    }
}

// MARK: - simultaneousGesture helper (scoped to this file)

private extension View {
    @ViewBuilder
    func simultaneousGesture<G: Gesture>(when enabled: Bool, _ gesture: @autoclosure () -> G) -> some View {
        if enabled { self.simultaneousGesture(gesture()) } else { self }
    }
}
