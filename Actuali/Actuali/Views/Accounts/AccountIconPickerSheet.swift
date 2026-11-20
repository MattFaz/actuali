import Foundation
import PhotosUI
import SwiftUI
import UIKit

struct AccountIconPickerSheet: View {
    enum Mode: String, Identifiable {
        case icons
        case upload

        var id: String {
            rawValue
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var iconStore = AccountIconCustomizationStore.shared
    let mode: Mode
    let budgetID: String?
    let account: Account

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var cropImageData: Data?
    @State private var isCroppingPhoto = false
    @State private var tintHex = AccountIconCustomization.defaultTint
    @State private var photoSaveFailed = false

    private let tints: [(hex: String, color: Color, name: LocalizedStringResource)] = [
        ("3478F6", .blue, "Blue"), ("8E5AE8", .purple, "Purple"), ("28A879", .green, "Green"),
        ("F28C28", .orange, "Orange"), ("E34D59", .red, "Red"), ("5D6B7A", .gray, "Gray"),
    ]
    private let symbols: [(symbol: String, name: LocalizedStringResource)] = [
        ("banknote.fill", "Cash"), ("building.columns.fill", "Bank"), ("creditcard.fill", "Credit Card"),
        ("lock.fill", "Privacy"), ("house.fill", "Home"), ("exclamationmark.triangle.fill", "Warning"),
        ("chart.line.uptrend.xyaxis", "Investments"), ("dollarsign.circle.fill", "Money"),
        ("wallet.pass.fill", "Wallet"), ("briefcase.fill", "Work"), ("car.fill", "Car"),
        ("airplane", "Travel"), ("gift.fill", "Gift"), ("heart.fill", "Heart"),
        ("star.fill", "Favorite"), ("leaf.fill", "Nature"), ("bolt.fill", "Power"),
        ("cart.fill", "Shopping Cart"), ("bag.fill", "Shopping Bag"), ("graduationcap.fill", "Education"),
        ("music.note", "Music"), ("gamecontroller.fill", "Games"), ("pawprint.fill", "Pets"),
        ("globe.americas.fill", "World"),
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .icons:
                    iconGrid
                case .upload:
                    uploadPicker
                }
            }
            .navigationDestination(isPresented: $isCroppingPhoto) {
                if let cropImageData {
                    AccountIconPhotoCropView(imageData: cropImageData) { croppedData in
                        Task {
                            let didSave = await iconStore.setPhoto(
                                croppedData, budgetID: budgetID, accountID: account.id
                            )
                            photoSaveFailed = !didSave
                            if photoSaveFailed {
                                isCroppingPhoto = false
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(mode == .icons ? "Icons" : "Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if mode == .icons,
                       iconStore.customization(for: budgetID, accountID: account.id) != nil {
                        Button(role: .destructive) {
                            iconStore.clear(accountID: account.id, budgetID: budgetID)
                            dismiss()
                        } label: {
                            Label("Use Default Icon", systemImage: "arrow.uturn.backward")
                        }
                        .accessibilityIdentifier("accountIcon.reset")
                    }
                }
            }
            .onAppear {
                tintHex = iconStore.customization(for: budgetID, accountID: account.id)?.tintHex
                    ?? AccountIconCustomization.defaultTint
            }
        }
    }

    private var uploadPicker: some View {
        VStack(spacing: 16) {
            if photoSaveFailed {
                Text("Couldn’t prepare that photo. Try another image.")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("Choose Photo", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhoto, matching: .images)
            .accessibilityIdentifier("accountIcon.choosePhoto")
        }
        .padding(24)
        .task {
            await Task.yield()
            isPhotoPickerPresented = true
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                photoSaveFailed = false
                defer { selectedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let preparedData = await AccountIconPhotoCropView.preparePhoto(data) else {
                    photoSaveFailed = true
                    return
                }
                cropImageData = preparedData
                isCroppingPhoto = true
            }
        }
    }

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 16)], spacing: 18) {
                ForEach(symbols, id: \.symbol) { icon in
                    Button {
                        iconStore.setSymbol(icon.symbol, tintHex: tintHex, budgetID: budgetID, accountID: account.id)
                        dismiss()
                    } label: {
                        Image(systemName: icon.symbol)
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(Color(hex: tintHex) ?? .blue)
                            .frame(width: 54, height: 54)
                            .background((Color(hex: tintHex) ?? .blue).opacity(0.13), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(icon.name))
                    .accessibilityIdentifier("accountIcon.icon.\(icon.symbol)")
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 22) {
                ForEach(tints, id: \.hex) { tint in
                    Button {
                        tintHex = tint.hex
                        iconStore.setTint(tint.hex, budgetID: budgetID, accountID: account.id)
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(.white, lineWidth: tintHex == tint.hex ? 3 : 0))
                            .overlay(Circle().stroke(tint.color, lineWidth: tintHex == tint.hex ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(tint.name))
                    .accessibilityIdentifier("accountIcon.tint.\(tint.hex)")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }
}

struct AccountIconPhotoCropView: View {
    @Environment(\.dismiss) private var dismiss
    let imageData: Data
    let onUsePhoto: (Data) -> Void

    @State private var image: UIImage?
    @State private var zoom = 1.0
    @State private var startingZoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragOrigin = CGSize.zero
    @State private var cropViewportSide: CGFloat = 320
    @State private var isSaving = false
    @State private var cropFailed = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Drag to position and pinch to zoom")
                .foregroundStyle(.secondary)

            if let image {
                cropPreview(image)
                    .frame(height: 320)
                VStack(spacing: 8) {
                    Text("Zoom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...4) { editing in
                        if !editing {
                            startingZoom = zoom
                        }
                    }
                    .accessibilityLabel("Zoom")
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView()
                    .frame(height: 320)
            }

            if cropFailed {
                Text("Couldn’t crop that photo. Try another image.")
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Use Photo", action: saveCrop)
                    .buttonStyle(.borderedProminent)
                    .disabled(image == nil || isSaving)
                    .accessibilityIdentifier("accountIcon.usePhoto")
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 24)
        .navigationTitle("Crop Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let image = UIImage(data: imageData) else {
                cropFailed = true
                return
            }
            self.image = image
        }
    }

    private func cropPreview(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, 320)
            let scale = max(side / image.size.width, side / image.size.height)

            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * scale * zoom, height: image.size.height * scale * zoom)
                    .offset(offset)
                Canvas { context, size in
                    var shade = Path()
                    shade.addRect(CGRect(origin: .zero, size: size))
                    shade.addEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5))
                    context.fill(shade, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                }
                .allowsHitTesting(false)
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .padding(1.5)
                    .allowsHitTesting(false)
            }
            .frame(width: side, height: side)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = AccountIconPhotoCropGeometry.clampedOffset(
                            CGSize(width: dragOrigin.width + value.translation.width,
                                   height: dragOrigin.height + value.translation.height),
                            side: side, imageSize: image.size, fitScale: scale, zoom: CGFloat(zoom)
                        )
                    }
                    .onEnded { _ in dragOrigin = offset }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in zoom = Double(min(4, max(1, CGFloat(startingZoom) * value.magnification))) }
                    .onEnded { _ in startingZoom = zoom }
            )
            .onAppear { cropViewportSide = side }
            .onChange(of: side) { _, newSide in cropViewportSide = newSide }
            .onChange(of: zoom) { _, newZoom in
                offset = AccountIconPhotoCropGeometry.clampedOffset(
                    offset, side: side, imageSize: image.size, fitScale: scale, zoom: CGFloat(newZoom)
                )
                dragOrigin = offset
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func saveCrop() {
        guard image != nil else { return }
        let side = cropViewportSide
        isSaving = true
        Task {
            if let cropped = await Self.cropPhoto(imageData, side: side, zoom: CGFloat(zoom), offset: offset) {
                onUsePhoto(cropped)
            } else {
                cropFailed = true
                isSaving = false
            }
        }
    }

    static func preparePhoto(_ data: Data) async -> Data? {
        await AccountIconImageEncoder.shared.jpegThumbnail(from: data, maxPixelSize: 2048, quality: 0.92)
    }

    static func cropPhoto(
        _ data: Data,
        side: CGFloat,
        zoom: CGFloat,
        offset: CGSize
    ) async -> Data? {
        await AccountIconImageEncoder.shared.cropPhoto(from: data, side: side, zoom: zoom, offset: offset)
    }
}

enum AccountIconPhotoCropGeometry {
    static func clampedOffset(
        _ offset: CGSize,
        side: CGFloat,
        imageSize: CGSize,
        fitScale: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let maxX = max(0, (imageSize.width * fitScale * zoom - side) / 2)
        let maxY = max(0, (imageSize.height * fitScale * zoom - side) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    static func cropRect(imageSize: CGSize, viewportSide: CGFloat, zoom: CGFloat, offset: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, viewportSide > 0, zoom > 0 else { return nil }
        let fitScale = max(viewportSide / imageSize.width, viewportSide / imageSize.height)
        let cropSide = min(min(imageSize.width, imageSize.height), viewportSide / (fitScale * zoom))
        let centerX = imageSize.width / 2 - offset.width / (fitScale * zoom)
        let centerY = imageSize.height / 2 - offset.height / (fitScale * zoom)
        let originX = min(max(centerX - cropSide / 2, 0), imageSize.width - cropSide)
        let originY = min(max(centerY - cropSide / 2, 0), imageSize.height - cropSide)
        return CGRect(x: originX, y: originY, width: cropSide, height: cropSide)
    }
}
