//
//  SettingsView.swift
//  Anywhere
//
//  Created by Junhui Lou on 2/21/26.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("ipv6Enabled", store: UserDefaults(suiteName: "group.com.argsment.Anywhere"))
    private var ipv6Enabled = false

    var body: some View {
        Form {
            Section {
                Toggle("IPv6", isOn: $ipv6Enabled)
            } footer: {
                Text("When disabled, connections to IPv6 destinations are dropped. Changes take effect on next connection.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
