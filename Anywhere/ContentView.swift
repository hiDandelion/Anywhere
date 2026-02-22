//
//  ContentView.swift
//  Anywhere
//
//  Created by Junhui Lou on 1/23/26.
//

import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var viewModel = VPNViewModel()

    @State private var showingAddSheet = false
    @State private var showingManualAddSheet = false

    private var isConnected: Bool {
        viewModel.vpnStatus == .connected
    }

    private var isTransitioning: Bool {
        viewModel.vpnStatus == .connecting || viewModel.vpnStatus == .disconnecting || viewModel.vpnStatus == .reasserting
    }

    var body: some View {
        NavigationView {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    powerButton
                        .padding(.bottom, 16)

                    Text(viewModel.statusText)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isConnected ? .white : .secondary)
                        .animation(.easeInOut, value: viewModel.vpnStatus)
                        .padding(.bottom, 40)

                    configurationCard
                        .padding(.horizontal, 24)

                    Spacer()
                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ConfigurationListView(viewModel: viewModel)
                    } label: {
                        Label("Configurations", systemImage: "server.rack")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                    AddConfigurationView(showingManualAddSheet: $showingManualAddSheet) { config in
                        viewModel.addConfiguration(config)
                    }
                }
            }
            .sheet(isPresented: $showingManualAddSheet) {
                ConfigurationEditorView { config in
                    viewModel.addConfiguration(config)
                }
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundGradient: some View {
        if isConnected {
            LinearGradient(
                colors: [Color("GradientStart"), Color("GradientMid"), Color("GradientEnd")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .transition(.opacity)
        } else {
            Color(.systemGroupedBackground)
                .transition(.opacity)
        }
    }

    // MARK: - Power Button

    private var powerButton: some View {
        Button {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                viewModel.toggleVPN()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(
                        isConnected ? Color.white.opacity(0.3) : Color.accentColor.opacity(0.15),
                        lineWidth: 4
                    )
                    .frame(width: 160, height: 160)

                Circle()
                    .fill(
                        isConnected
                            ? .ultraThinMaterial
                            : .regularMaterial
                    )
                    .frame(width: 140, height: 140)
                    .shadow(color: isConnected ? .cyan.opacity(0.4) : .black.opacity(0.08), radius: isConnected ? 24 : 8)

                if isTransitioning {
                    ProgressView()
                        .controlSize(.large)
                        .tint(isConnected ? .white : .accentColor)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(isConnected ? .white : .accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isButtonDisabled)
        .animation(.easeInOut(duration: 0.6), value: isConnected)
    }

    // MARK: - Configuration Card

    @ViewBuilder
    private var configurationCard: some View {
        if let config = viewModel.selectedConfiguration {
            selectedConfigurationCard(config)
        } else {
            emptyStateCard
        }
    }

    private func selectedConfigurationCard(_ config: VLESSConfiguration) -> some View {
        NavigationLink {
            ConfigurationListView(viewModel: viewModel)
        } label: {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(isConnected ? .white.opacity(0.7) : .secondary)
                        .frame(width: 24)
                    Text(config.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isConnected ? .white : .primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isConnected ? Color.white.opacity(0.4) : Color.secondary.opacity(0.4))
                }

                Divider()
                    .overlay(isConnected ? Color.white.opacity(0.15) : nil)

                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(isConnected ? .white.opacity(0.5) : .secondary)
                        .frame(width: 24)
                    Text("\(config.serverAddress):\(config.serverPort, format: .number.grouping(.never))")
                        .font(.footnote)
                        .foregroundStyle(isConnected ? .white.opacity(0.7) : .secondary)
                    Spacer()
                    Text(config.security.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isConnected ? .white.opacity(0.8) : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(isConnected ? .white.opacity(0.15) : Color.secondary.opacity(0.12))
                        )
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isConnected ? .ultraThinMaterial : .regularMaterial)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyStateCard: some View {
        Button {
            showingAddSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Add a Configuration")
                    .font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
        }
        .buttonStyle(.plain)
    }
}
