//
//  AddConfigurationView.swift
//  Anywhere
//
//  Created by Junhui Lou on 2/16/26.
//

import SwiftUI

fileprivate enum Method: String, CaseIterable, Identifiable {
    var id: String { self.rawValue }

    case qrCode = "qrCode"
    case link = "link"
    case manual = "manual"

    var systemImage: String {
        switch self {
        case .qrCode: "qrcode.viewfinder"
        case .link: "link"
        case .manual: "hand.point.up.left"
        }
    }

    var title: String {
        switch self {
        case .qrCode: "QR Code"
        case .link: "VLESS Link"
        case .manual: "Manual"
        }
    }
}

struct AddConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var showingManualAddSheet: Bool
    var onImport: ((VLESSConfiguration) -> Void)?

    @State private var selectedMethod: Method?
    @State private var showingQRScanner = false
    @State private var linkURL = ""
    @State private var showingLinkError = false
    @State private var linkErrorMessage = ""

    var body: some View {
        VStack {
            methodPicker
                .geometryGroup()

            if selectedMethod == .link {
                linkInputField
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .geometryGroup()
            }

            Button {
                handleContinue()
            } label: {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .disabled(isContinueDisabled)
            .buttonStyle(.glassProminent)
            .padding(.top, 15)
            .geometryGroup()
        }
        .padding([.horizontal, .top], 20)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onChange(of: selectedMethod) {
            if selectedMethod == .link && linkURL.isEmpty {
                checkClipboard()
            }
        }
        .qrScanner(isScanning: $showingQRScanner) { code in
            importFromString(code)
        }
        .alert("Invalid VLESS Link", isPresented: $showingLinkError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(linkErrorMessage)
        }
    }

    private var isContinueDisabled: Bool {
        switch selectedMethod {
        case .link: linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case nil: true
        default: false
        }
    }

    // MARK: - Method Picker

    @ViewBuilder
    var methodPicker: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add Configuration")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 15, height: 15)
                        .padding(10)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)

            ForEach(Method.allCases) { method in
                let isSelected: Bool = selectedMethod == method

                HStack(spacing: 10) {
                    Image(systemName: method.systemImage)
                        .font(.title)
                        .frame(width: 40)

                    Text(method.title)
                        .fontWeight(.semibold)

                    Spacer(minLength: 0)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect)
                        .foregroundStyle(isSelected ? Color.blue : Color.gray.opacity(0.2))
                }
                .padding(.vertical, 6)
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.snappy) {
                        selectedMethod = isSelected ? nil : method
                    }
                }
            }
        }
    }

    // MARK: - Link Input

    private var linkInputField: some View {
        TextField("vless://", text: $linkURL, axis: .vertical)
            .textFieldStyle(LinkTextFieldStyle())
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .padding(.top, 12)
    }

    // MARK: - Actions

    private func checkClipboard() {
        if let clip = UIPasteboard.general.string,
           clip.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("vless://") {
            linkURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func handleContinue() {
        switch selectedMethod {
        case .qrCode:
            showingQRScanner = true
        case .link:
            importFromLink()
        case .manual:
            showingManualAddSheet = true
            dismiss()
        case .none:
            break
        }
    }

    private func importFromLink() {
        importFromString(linkURL)
    }

    private func importFromString(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let config = try VLESSConfiguration.parse(url: trimmed)
            onImport?(config)
            dismiss()
        } catch {
            linkErrorMessage = error.localizedDescription
            showingLinkError = true
        }
    }
}

private struct LinkTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(16)
            .background(.gray.opacity(0.1), in: .capsule)
            .lineLimit(1)
    }
}
