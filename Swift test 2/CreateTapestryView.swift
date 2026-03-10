import SwiftUI

// MARK: - Create Tapestry Sheet

struct CreateTapestryView: View {
    @Environment(TapestryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var titleError: String?
    @State private var canvasMode: CanvasMode = .infinite

    var onCreated: ((Tapestry) -> Void)?

    private var canCreate: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    fieldsSection
                    canvasModeSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New Tapestry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createTapestry() }
                        .fontWeight(.semibold)
                        .disabled(!canCreate)
                }
            }
        }
    }

    // MARK: Fields

    private var fieldsSection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("My Tapestry", text: $title)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: title) { _, _ in titleError = nil }

                if let err = titleError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("What's this tapestry about? (optional)", text: $description, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(3...5)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: Canvas Mode Picker

    private var canvasModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canvas Type")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                canvasModeCard(
                    mode: .infinite,
                    icon: "arrow.up.left.and.arrow.down.right",
                    title: "Infinite Canvas",
                    subtitle: "Pan & zoom freely in all directions"
                )
                canvasModeCard(
                    mode: .vertical,
                    icon: "arrow.up.and.down",
                    title: "Vertical Feed",
                    subtitle: "Scroll top to bottom like a feed"
                )
            }
        }
    }

    private func canvasModeCard(mode: CanvasMode, icon: String, title: String, subtitle: String) -> some View {
        let selected = canvasMode == mode
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { canvasMode = mode }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(selected ? .white : .secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? .white : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.clear : Color(.separator).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Create Action

    private func createTapestry() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            titleError = "Title can't be empty."
            return
        }
        let tapestry = Tapestry(
            title: trimmed,
            description: description.trimmingCharacters(in: .whitespaces),
            type: .personal
        )
        store.add(tapestry)
        store.setCanvasMode(tapestryID: tapestry.id, mode: canvasMode)
        onCreated?(tapestry)
        dismiss()
    }
}
