import SwiftUI
import PhotosUI
import UIKit

// MARK: - ProfileSettingsView

private struct CropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

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
    @State private var cropItem: CropItem? = nil

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
                            if let data = try? await newItem?.loadTransferable(type: Data.self),
                               let uiImage = UIImage(data: data) {
                                cropItem = CropItem(image: normalizedImage(uiImage))
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
            .fullScreenCover(item: $cropItem) { item in
                PhotoCropView(image: item.image) { croppedImage in
                    cropItem = nil
                    if let data = croppedImage.jpegData(compressionQuality: 0.85) {
                        coverPhotoData = data
                        try? data.write(to: photoURL)
                        hasPhoto = true
                        if let uid = auth.userID {
                            Task { await ProfileService.uploadAvatar(data, userID: uid) }
                        }
                    }
                } onCancel: {
                    cropItem = nil
                }
            }
        }
    }

    // MARK: - Helpers

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

    private func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

// MARK: - PhotoCropView

struct PhotoCropView: View {
    let image: UIImage
    let onComplete: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let cropSize: CGFloat = 280

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image layer
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cropSize, height: cropSize)
                .scaleEffect(scale, anchor: .center)
                .offset(offset)

            // Dark overlay with circular cutout
            ZStack {
                Color.black.opacity(0.55)
                Circle()
                    .frame(width: cropSize, height: cropSize)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Circle border
            Circle()
                .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                .frame(width: cropSize, height: cropSize)
                .allowsHitTesting(false)

            // Gesture capture layer
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(
                    SimultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset },
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, lastScale * value)
                            }
                            .onEnded { _ in lastScale = scale }
                    )
                )

            // UI controls
            VStack {
                HStack {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                    Spacer()
                    Button("Choose") { onComplete(croppedImage()) }
                        .foregroundStyle(.white)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                }
                Spacer()
                Text("Move and Scale")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 60)
            }
        }
    }

    private func croppedImage() -> UIImage {
        let aspect = image.size.width / image.size.height
        let displayedWidth: CGFloat
        let displayedHeight: CGFloat
        if aspect >= 1 {
            displayedHeight = cropSize * scale
            displayedWidth = cropSize * aspect * scale
        } else {
            displayedWidth = cropSize * scale
            displayedHeight = cropSize / aspect * scale
        }

        let scaleX = image.size.width / displayedWidth
        let scaleY = image.size.height / displayedHeight

        let cropOriginX = (-cropSize / 2 - offset.width + displayedWidth / 2) * scaleX
        let cropOriginY = (-cropSize / 2 - offset.height + displayedHeight / 2) * scaleY
        let cropW = cropSize * scaleX
        let cropH = cropSize * scaleY

        let clampedX = max(0, min(cropOriginX, image.size.width - 1))
        let clampedY = max(0, min(cropOriginY, image.size.height - 1))
        let clampedW = min(cropW, image.size.width - clampedX)
        let clampedH = min(cropH, image.size.height - clampedY)

        let pixelCropRect = CGRect(x: clampedX * image.scale,
                                   y: clampedY * image.scale,
                                   width: clampedW * image.scale,
                                   height: clampedH * image.scale)

        guard let cgImage = image.cgImage?.cropping(to: pixelCropRect) else { return image }

        let outputSize = CGSize(width: 400, height: 400)
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }
}

#Preview {
    ProfileSettingsView()
        .environment(AuthManager())
}
