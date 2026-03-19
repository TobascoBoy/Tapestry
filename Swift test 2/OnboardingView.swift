import SwiftUI
import PhotosUI

struct OnboardingView: View {
    @Environment(AuthManager.self) private var auth

    @AppStorage("profile_name")      private var name:     String = ""
    @AppStorage("profile_bio")       private var bio:      String = ""
    @AppStorage("profile_pronouns")  private var pronouns: String = ""
    @AppStorage("profile_has_photo") private var hasPhoto: Bool   = false

    var onSkip: () -> Void
    var onCreateTapestry: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var isSaving = false

    private var photoURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile_photo.jpg")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Text("Welcome to Tapestry")
                        .font(.custom("Avenir-Light", size: 28))
                        .tracking(2)
                    Text("Set up your profile to get started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 52)
                .padding(.bottom, 36)

                // Avatar
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        avatarPreview
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(UIColor.systemGray4), lineWidth: 1))

                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                            )
                            .overlay(Circle().stroke(Color(UIColor.systemGray4), lineWidth: 1))
                            .offset(x: 4, y: 4)
                    }
                }
                .buttonStyle(.plain)
                .onChange(of: selectedPhotoItem) { _, newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self) {
                            avatarData = data
                            try? data.write(to: photoURL)
                            hasPhoto = true
                        }
                    }
                }
                .padding(.bottom, 32)

                // Fields
                VStack(spacing: 0) {
                    fieldRow(label: "Name", placeholder: "Your name", text: $name)
                    Divider().padding(.leading, 16)
                    fieldRow(label: "Pronouns", placeholder: "e.g. they/them", text: $pronouns)
                    Divider().padding(.leading, 16)
                    bioRow
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)

                Spacer().frame(height: 36)

                // Create tapestry CTA
                VStack(spacing: 12) {
                    Button {
                        save()
                        onCreateTapestry()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black)
                                .frame(height: 52)
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "rectangle.stack.badge.plus")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("Create My First Tapestry")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                            }
                        }
                    }
                    .disabled(isSaving)
                    .padding(.horizontal, 24)

                    Button {
                        save()
                        onSkip()
                    } label: {
                        Text("Skip for now")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            // Pre-load existing avatar if present
            if hasPhoto, let data = try? Data(contentsOf: photoURL) {
                avatarData = data
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var avatarPreview: some View {
        if let data = avatarData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color(red: 0.4, green: 0.6, blue: 1.0),
                         Color(red: 0.6, green: 0.4, blue: 1.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Text(name.isEmpty ? "?" : String(name.prefix(1)).uppercased())
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
        }
    }

    private func fieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 15))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var bioRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bio")
                .font(.system(size: 15, weight: .medium))
            TextField("Write something about yourself…", text: $bio, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(4, reservesSpace: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Save

    private func save() {
        guard let uid = auth.userID else { return }
        if let data = avatarData {
            Task(priority: .utility) {
                await ProfileService.uploadAvatar(data, userID: uid)
            }
        }
        ProfileService.saveText(userID: uid, name: name, bio: bio, pronouns: pronouns)
    }
}
