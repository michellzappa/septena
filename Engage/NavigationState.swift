import SwiftUI

struct NavigationState: ObservableObject {
    @Published var selectedTab: Tab = .inbox
    @Published var showingQuickEntry = false
    @Published var showingServerConfig = false
    @Published var showingAgentPanel = false
    @Published var autoStartEntry = false
    @Published var serverURL: String? = nil
    @Published var apiKey: String? = nil

    enum Tab: Int, CaseIterable, Identifiable {
        case inbox = 0, today, upcoming, anytime, projects, areas, logbook, review, settings
        var id: Int { rawValue }
    }
}
