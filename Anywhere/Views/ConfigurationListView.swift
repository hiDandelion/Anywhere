//
//  ConfigurationListView.swift
//  Anywhere
//
//  List of VLESS configurations with add/edit/delete
//

import SwiftUI

struct ConfigurationListView: View {
    @ObservedObject var viewModel: VPNViewModel

    @State private var editorConfig: VLESSConfiguration?
    @State private var showingAddSheet = false
    @State private var showingManualAddSheet = false

    var body: some View {
        List {
            ForEach(viewModel.configurations) { config in
                configRow(config)
            }
        }
        .overlay {
            if viewModel.configurations.isEmpty {
                ContentUnavailableView(
                    "No Configurations",
                    systemImage: "network.slash",
                    description: Text("Tap + to add a VLESS configuration.")
                )
            }
        }
        .navigationTitle("Configurations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
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
        .sheet(item: $editorConfig) { config in
            ConfigurationEditorView(existingConfiguration: config) { updated in
                viewModel.updateConfiguration(updated)
            }
        }
    }

    @ViewBuilder
    private func configRow(_ config: VLESSConfiguration) -> some View {
        Button {
            viewModel.selectedConfiguration = config
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.name)
                        .font(.body)
                    Text("\(config.serverAddress):\(config.serverPort, format: .number.grouping(.never))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.selectedConfiguration?.id == config.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") {
                editorConfig = config
            }
            Button("Delete", role: .destructive) {
                viewModel.deleteConfiguration(config)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                viewModel.deleteConfiguration(config)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editorConfig = config
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }
}
