//
//  ConfigurationProvider.swift
//  Anywhere
//
//  Configuration loading and management
//

import Foundation

/// Protocol for loading VPN configurations
protocol ConfigurationProviding {
    func loadConfigurations() -> [VLESSConfiguration]
}
