import SwiftUI
import UIKit

// MARK: - Shared font & color data

let textStickerFontChoices: [FontChoice] = {
    var choices: [FontChoice] = []
    choices.append(FontChoice(name: "Modern",  uiFont: .systemFont(ofSize: 64, weight: .semibold)))
    if let desc = UIFont.systemFont(ofSize: 64, weight: .bold).fontDescriptor.withDesign(.rounded) {
        choices.append(FontChoice(name: "Rounded", uiFont: UIFont(descriptor: desc, size: 64)))
    }
    if let f = UIFont(name: "Georgia-Bold",          size: 64) { choices.append(FontChoice(name: "Serif",  uiFont: f)) }
    if let f = UIFont(name: "CourierNewPS-BoldMT",   size: 64) { choices.append(FontChoice(name: "Mono",   uiFont: f)) }
    if let f = UIFont(name: "SnellRoundhand-Bold",   size: 64) { choices.append(FontChoice(name: "Script", uiFont: f)) }
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

struct TextStickerContent {
    let text: String
    let fontIndex: Int
    let colorIndex: Int
    let image: UIImage

    init(text: String, fontIndex: Int, colorIndex: Int) {
        self.text = text
        self.fontIndex = fontIndex
        self.colorIndex = colorIndex
        self.image = TextStickerContent.render(text: text, fontIndex: fontIndex, colorIndex: colorIndex)
    }

    static func render(text: String, fontIndex: Int, colorIndex: Int) -> UIImage {
        let font = textStickerFontChoices[safe: fontIndex]?.uiFont ?? .systemFont(ofSize: 64, weight: .semibold)
        let color = textStickerColorOptions[safe: colorIndex] ?? .label
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.boundingRect(
            with: CGSize(width: 1200, height: 600),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        let padding: CGFloat = 20
        let imgSize = CGSize(width: ceil(textSize.width) + padding * 2,
                             height: ceil(textSize.height) + padding * 2)
        let renderer = UIGraphicsImageRenderer(size: imgSize)
        return renderer.image { _ in str.draw(at: CGPoint(x: padding, y: padding)) }
    }
}

private extension Array {
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
                    Text(text.isEmpty ? "Your text" : text)
                        .font(Font(selectedFont.uiFont.withSize(36)))
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color(selectedUIColor))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
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
                                                 colorIndex: selectedColorIndex))
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
