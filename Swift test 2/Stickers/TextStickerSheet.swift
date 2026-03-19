import SwiftUI
import UIKit

// MARK: - Shared font & color data

let textStickerFontChoices: [FontChoice] = {
    var choices: [FontChoice] = []

    // System variants
    choices.append(FontChoice(name: "Modern",  uiFont: .systemFont(ofSize: 64, weight: .semibold)))
    if let desc = UIFont.systemFont(ofSize: 64, weight: .bold).fontDescriptor.withDesign(.rounded) {
        choices.append(FontChoice(name: "Rounded", uiFont: UIFont(descriptor: desc, size: 64)))
    }

    // Sans-serif
    if let f = UIFont(name: "AvenirNext-Bold",             size: 64) { choices.append(FontChoice(name: "Avenir",      uiFont: f)) }
    if let f = UIFont(name: "Futura-Bold",                 size: 64) { choices.append(FontChoice(name: "Futura",      uiFont: f)) }
    if let f = UIFont(name: "GillSans-Bold",               size: 64) { choices.append(FontChoice(name: "Gill Sans",   uiFont: f)) }
    if let f = UIFont(name: "Futura-CondensedExtraBold",   size: 64) { choices.append(FontChoice(name: "Condensed",   uiFont: f)) }

    // Serif
    if let f = UIFont(name: "Georgia-Bold",                size: 64) { choices.append(FontChoice(name: "Serif",       uiFont: f)) }
    if let f = UIFont(name: "Baskerville-Bold",            size: 64) { choices.append(FontChoice(name: "Baskerville", uiFont: f)) }
    if let f = UIFont(name: "Didot-Bold",                  size: 64) { choices.append(FontChoice(name: "Didot",       uiFont: f)) }
    if let f = UIFont(name: "Copperplate-Bold",            size: 64) { choices.append(FontChoice(name: "Copperplate", uiFont: f)) }
    if let f = UIFont(name: "AmericanTypewriter-Bold",     size: 64) { choices.append(FontChoice(name: "Typewriter",  uiFont: f)) }

    // Handwriting / Display
    if let f = UIFont(name: "SnellRoundhand-Bold",         size: 64) { choices.append(FontChoice(name: "Script",      uiFont: f)) }
    if let f = UIFont(name: "BradleyHandITCTT-Bold",       size: 64) { choices.append(FontChoice(name: "Bradley",     uiFont: f)) }
    if let f = UIFont(name: "Noteworthy-Bold",             size: 64) { choices.append(FontChoice(name: "Noteworthy",  uiFont: f)) }
    if let f = UIFont(name: "MarkerFelt-Wide",             size: 64) { choices.append(FontChoice(name: "Marker",      uiFont: f)) }
    if let f = UIFont(name: "Chalkduster",                 size: 64) { choices.append(FontChoice(name: "Chalk",       uiFont: f)) }

    // Mono
    if let f = UIFont(name: "CourierNewPS-BoldMT",         size: 64) { choices.append(FontChoice(name: "Mono",        uiFont: f)) }

    return choices
}()

let textStickerColorOptions: [UIColor] = [
    .label, .systemBackground,
    .systemRed, .systemOrange, .systemYellow,
    .systemGreen, .systemBlue, .systemPurple, .systemPink
]

// MARK: - FontChoice

struct FontChoice: Identifiable {
    let id = UUID()
    let name: String
    let uiFont: UIFont
}

// MARK: - TextStickerContent

extension TextStickerContent {
    /// Constructs from the text fields shared by `StickerState` and `StickerOp`.
    /// Returns nil if any required field is missing.
    static func deserialize(
        textString: String?, fontIndex: Int?, colorIndex: Int?,
        wrapWidth: Double?, alignment: Int?, bgStyle: Int?
    ) -> TextStickerContent? {
        guard let text = textString, let fi = fontIndex, let ci = colorIndex else { return nil }
        return TextStickerContent(text: text, fontIndex: fi, colorIndex: ci,
                                  wrapWidth: wrapWidth.map { CGFloat($0) } ?? 900,
                                  alignment: alignment ?? 1, bgStyle: bgStyle ?? 1)
    }
}

struct TextStickerContent {
    let text:       String
    let fontIndex:  Int
    let colorIndex: Int
    let wrapWidth:  CGFloat  // render-space wrap width; drag corner handle to change
    let alignment:  Int      // 0=left  1=center  2=right
    let bgStyle:    Int      // 0=none  1=solid dark pill
    let image:      UIImage

    init(text: String, fontIndex: Int, colorIndex: Int,
         wrapWidth: CGFloat = 900, alignment: Int = 1, bgStyle: Int = 1) {
        self.text       = text
        self.fontIndex  = fontIndex
        self.colorIndex = colorIndex
        self.wrapWidth  = wrapWidth
        self.alignment  = alignment
        self.bgStyle    = bgStyle
        self.image = TextStickerContent.render(
            text: text, fontIndex: fontIndex, colorIndex: colorIndex,
            wrapWidth: wrapWidth, alignment: alignment, bgStyle: bgStyle)
    }

    static func render(text: String, fontIndex: Int, colorIndex: Int,
                       wrapWidth: CGFloat = 900, alignment: Int = 1, bgStyle: Int = 1) -> UIImage {
        let font  = textStickerFontChoices[safe: fontIndex]?.uiFont ?? .systemFont(ofSize: 64, weight: .semibold)
        let color = textStickerColorOptions[safe: colorIndex] ?? .white

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = {
            switch alignment {
            case 0:  return .left
            case 2:  return .right
            default: return .center
            }
        }()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.boundingRect(
            with: CGSize(width: wrapWidth, height: 4000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size

        let hPad: CGFloat = bgStyle == 1 ? 32 : 20
        let vPad: CGFloat = bgStyle == 1 ? 20 : 10
        let imgSize = CGSize(width:  ceil(textSize.width)  + hPad * 2,
                             height: ceil(textSize.height) + vPad * 2)

        return UIGraphicsImageRenderer(size: imgSize).image { _ in
            if bgStyle == 1 {
                UIColor.black.withAlphaComponent(0.72).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: imgSize),
                             cornerRadius: 14).fill()
            }
            str.draw(in: CGRect(x: hPad, y: vPad,
                                width: ceil(textSize.width), height: ceil(textSize.height)))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - TextStickerSheet

struct TextStickerSheet: View {
    let initialContent: TextStickerContent?
    let onAdd: (TextStickerContent) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var selectedFontIndex: Int
    @State private var selectedColorIndex: Int
    @FocusState private var isFocused: Bool

    private var isEditing: Bool { initialContent != nil }
    private var selectedFont: FontChoice { textStickerFontChoices[safe: selectedFontIndex] ?? textStickerFontChoices[0] }
    private var selectedUIColor: UIColor { textStickerColorOptions[safe: selectedColorIndex] ?? .label }
    private var canConfirm: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(initialContent: TextStickerContent? = nil,
         onAdd: @escaping (TextStickerContent) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialContent = initialContent
        self.onAdd = onAdd
        self.onCancel = onCancel
        _text = State(initialValue: initialContent?.text ?? "")
        _selectedFontIndex = State(initialValue: initialContent?.fontIndex ?? 0)
        _selectedColorIndex = State(initialValue: initialContent?.colorIndex ?? 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Live preview
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemGroupedBackground))
                    ScrollView {
                        Text(text.isEmpty ? "Your text" : text)
                            .font(Font(selectedFont.uiFont.withSize(36)))
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color(selectedUIColor))
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 110, maxHeight: 200)
                .padding(.horizontal)
                .padding(.top, 20)

                // Text input
                TextField("Enter text…", text: $text)
                    .focused($isFocused)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal)
                    .padding(.top, 20)

                // Font picker
                sectionLabel("Font")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(textStickerFontChoices.indices, id: \.self) { i in
                            fontCard(textStickerFontChoices[i], index: i)
                        }
                    }
                    .padding(.horizontal)
                }

                // Color picker
                sectionLabel("Color")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(textStickerColorOptions.indices, id: \.self) { i in
                            colorDot(textStickerColorOptions[i], index: i)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle(isEditing ? "Edit Text" : "Add Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "Done" : "Add") {
                        onAdd(TextStickerContent(text: text,
                                                 fontIndex: selectedFontIndex,
                                                 colorIndex: selectedColorIndex,
                                                 wrapWidth: initialContent?.wrapWidth ?? 900,
                                                 alignment: initialContent?.alignment ?? 1,
                                                 bgStyle:   initialContent?.bgStyle   ?? 1))
                    }
                    .fontWeight(.semibold)
                    .disabled(!canConfirm)
                }
            }
            .onAppear { isFocused = true }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private func fontCard(_ choice: FontChoice, index: Int) -> some View {
        let selected = selectedFontIndex == index
        VStack(spacing: 4) {
            Text("Aa")
                .font(Font(choice.uiFont.withSize(26)))
                .frame(width: 68, height: 46)
            Text(choice.name)
                .font(.caption.weight(.medium))
        }
        .frame(width: 80)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                )
        )
        .onTapGesture {
            selectedFontIndex = index
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    @ViewBuilder
    private func colorDot(_ color: UIColor, index: Int) -> some View {
        let selected = selectedColorIndex == index
        Circle()
            .fill(Color(color))
            .frame(width: 36, height: 36)
            .overlay(
                Circle().stroke(
                    selected ? Color.accentColor : Color.primary.opacity(0.15),
                    lineWidth: selected ? 2.5 : 1
                )
            )
            .shadow(color: .black.opacity(0.08), radius: 2)
            .onTapGesture {
                selectedColorIndex = index
                UISelectionFeedbackGenerator().selectionChanged()
            }
    }
}
