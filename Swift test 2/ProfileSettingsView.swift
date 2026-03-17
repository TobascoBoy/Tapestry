import SwiftUI
import PhotosUI

struct ProfileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var auth

    @AppStorage("profile_name")      private var name:        String = ""
    @AppStorage("profile_bio")       private var bio:         String = ""
    @AppStorage("profile_pronouns")  private var pronouns:    String = ""
    @AppStorage("profile_has_photo") private var hasPhoto:    Bool   = false
    @AppStorage("app_appearance")    private var appAppearance: Int  = 0

    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var coverPhotoData: Data? = nil
    @State private var showSignOutConfirm = false

    private var photoURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile_photo.jpg")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack(spacing: 14) {
                            coverPhotoPreview
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color(UIColor.systemGray4), lineWidth: 1))

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Profile Photo")
                                    .font(.system(size: 15, weight: .medium))
                                Text("Tap to change")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                coverPhotoData = data
                                try? data.write(to: photoURL)
                                hasPhoto = true
                                if let uid = auth.userID {
                                    await ProfileService.uploadAvatar(data, userID: uid)
                                }
                            }
                        }
                    }

                    HStack {
                        Text("Name")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        TextField("Your name", text: $name)
                            .font(.system(size: 15))
                    }

                    HStack {
                        Text("Pronouns")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 80, alignment: .leading)
                        TextField("e.g. they/them", text: $pronouns)
                            .font(.system(size: 15))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bio")
                            .font(.system(size: 15, weight: .medium))
                        TextField("Write something about yourself…", text: $bio, axis: .vertical)
                            .font(.system(size: 15))
                            .lineLimit(4, reservesSpace: true)
                    }
                    .padding(.vertical, 4)

                } header: {
                    Text("Profile")
                }

                Section {
                    Picker("Appearance", selection: $appAppearance) {
                        Text("System Default").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Text("Sign Out")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if let uid = auth.userID {
                            ProfileService.saveText(userID: uid, name: name,
                                                    bio: bio, pronouns: pronouns)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if hasPhoto, let data = try? Data(contentsOf: photoURL) {
                    coverPhotoData = data
                }
            }
            .confirmationDialog("Sign out of your account?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { try? await auth.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var coverPhotoPreview: some View {
        if let data = coverPhotoData, let uiImage = UIImage(data: data) {
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
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
        }
    }
}

#Preview {
    ProfileSettingsView()
        .environment(AuthManager())
}
