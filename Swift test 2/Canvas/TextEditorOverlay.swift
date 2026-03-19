import SwiftUI
import UIKit

// MARK: - TextEditorOverlay

struct TextEditorOverlay: View {
    let initialContent: TextStickerContent?
    let onComplete: (TextStickerContent) -> Void
    let onCancel:   () -> Void

    @State private var text:       String
    @State private var fontIndex:  Int
    @State private var colorIndex: Int
    @State private var alignment:  Int   // 0=left 1=center 2=right
    @State private var bgStyle:    Int   // 0=none 1=solid
    @State private var showColors  = false

    init(initialContent: TextStickerContent? = nil,
         onComplete: @escaping (TextStickerContent) -> Void,
         onCancel:   @escaping () -> Void) {
        self.initialContent = initialContent
        self.onComplete = onComplete
        self.onCancel   = onCancel
        _text       = State(initialValue: initialContent?.text ?? "")
        _fontIndex  = State(initialValue: initialContent?.fontIndex  ?? 0)
        _colorIndex = State(initialValue: initialContent?.colorIndex ?? 1)  // white default
        _alignment  = State(initialValue: initialContent?.alignment  ?? 1)
        _bgStyle    = State(initialValue: initialContent?.bgStyle    ?? 1)
    }

    // MARK: - Computed helpers

    private var uiFont: UIFont {
        (textStickerFontChoices[safe: fontIndex]?.uiFont
            ?? .systemFont(ofSize: 40, weight: .semibold)).withSize(40)
    }
    private var textUIColor: UIColor {
        textStickerColorOptions[safe: colorIndex] ?? .white
    }
    private var nsAlignment: NSTextAlignment {
        switch alignment {
        case 0:  return .left
        case 2:  return .right
        default: return .center
        }
    }
    private var canConfirm: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
        }
        .overlay {
            VStack(spacing: 0) {

                // ── Top bar ──────────────────────────────────────────────
                HStack {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(.white)
                        .font(.system(size: 17))
                    Spacer()
                    Button("Done") {
                        guard canConfirm else { return }
                        onComplete(makeContent())
                    }
                    .foregroundStyle(canConfirm ? .white : Color.white.opacity(0.35))
                    .font(.system(size: 17, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Spacer()

                // ── Inline text box ──────────────────────────────────────
                ZStack {
                    if bgStyle == 1 {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.72))
                    }
                    ZStack {
                        if text.isEmpty {
                            Text("Tap to type…")
                                .font(Font(uiFont))
                                .foregroundStyle(Color(textUIColor).opacity(0.35))
                                .multilineTextAlignment(.center)
                        }
                        InlineTextView(
                            text: $text,
                            font: uiFont,
                            textColor: textUIColor,
                            alignment: nsAlignment
                        )
                    }
                    .padding(.horizontal, bgStyle == 1 ? 14 : 0)
                    .padding(.vertical,   bgStyle == 1 ? 10 : 0)
                }
                .padding(.horizontal, 28)
                .animation(.spring(response: 0.25), value: bgStyle)

                Spacer()

                // ── Color row (shown when color wheel tapped) ─────────────
                if showColors {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(textStickerColorOptions.indices, id: \.self) { i in
                                let sel = colorIndex == i
                                Circle()
                                    .fill(Color(textStickerColorOptions[i]))
                                    .frame(width: sel ? 34 : 28, height: sel ? 34 : 28)
                                    .overlay(Circle().stroke(Color.white, lineWidth: sel ? 2.5 : 1))
                                    .animation(.spring(response: 0.2), value: sel)
                                    .onTapGesture {
                                        colorIndex = i
                                        UISelectionFeedbackGenerator().selectionChanged()
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .frame(height: 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ── Font picker ──────────────────────────────────────────
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(textStickerFontChoices.indices, id: \.self) { i in
                            let sel = fontIndex == i
                            Button {
                                fontIndex = i
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                Text(textStickerFontChoices[i].name)
                                    .font(Font(textStickerFontChoices[i].uiFont.withSize(18)))
                                    .foregroundStyle(sel ? Color.white : Color.white.opacity(0.45))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical,   10)
                                    .background(
                                        sel ? AnyView(RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.18))) : AnyView(Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 46)

                // ── Toolbar ──────────────────────────────────────────────
                HStack(spacing: 0) {
                    // Color wheel
                    Button {
                        withAnimation(.spring(response: 0.3)) { showColors.toggle() }
                    } label: {
                        Circle()
                            .fill(AngularGradient(
                                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
                                center: .center
                            ))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(
                                showColors ? Color.white : Color.white.opacity(0.4),
                                lineWidth: showColors ? 2.5 : 1.5
                            ))
                    }
                    .frame(maxWidth: .infinity)

                    // Alignment
                    Button {
                        alignment = (alignment + 1) % 3
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Image(systemName: alignmentIcon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)

                    // Background style toggle
                    Button {
                        bgStyle = bgStyle == 0 ? 1 : 0
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(bgStyle == 1 ? Color.white : Color.clear)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.white.opacity(0.6),
                                                lineWidth: bgStyle == 0 ? 1.5 : 0)
                                )
                            Text("A")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(bgStyle == 1 ? Color.black : Color.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Helpers

    private var alignmentIcon: String {
        switch alignment {
        case 0:  return "text.alignleft"
        case 2:  return "text.alignright"
        default: return "text.aligncenter"
        }
    }

    private func makeContent() -> TextStickerContent {
        TextStickerContent(
            text: text,
            fontIndex: fontIndex,
            colorIndex: colorIndex,
            wrapWidth: initialContent?.wrapWidth ?? 900,
            alignment: alignment,
            bgStyle: bgStyle
        )
    }
}

// MARK: - InlineTextView (auto-sizing UITextView)

private struct InlineTextView: UIViewRepresentable {
    @Binding var text: String
    let font:      UIFont
    let textColor: UIColor
    let alignment: NSTextAlignment

    func makeUIView(context: Context) -> AutoSizingTextView {
        let tv = AutoSizingTextView()
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.font      = font
        tv.textColor = textColor
        tv.textAlignment = alignment
        tv.delegate  = context.coordinator
        tv.autocorrectionType     = .yes
        tv.autocapitalizationType = .sentences
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async { tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ tv: AutoSizingTextView, context: Context) {
        if tv.text != text { tv.text = text }
        tv.font      = font
        tv.textColor = textColor
        tv.textAlignment = alignment
        tv.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }
        func textViewDidChange(_ tv: UITextView) { text = tv.text }
    }
}

private final class AutoSizingTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let size = sizeThatFits(CGSize(width: frame.width, height: .infinity))
        return CGSize(width: UIView.noIntrinsicMetric,
                      height: max(size.height, font?.lineHeight ?? 50))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}
