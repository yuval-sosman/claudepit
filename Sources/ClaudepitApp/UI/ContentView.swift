import SwiftUI

struct ContentView: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 12) {
            // One banner for the whole window: the Q&A surfaces that need a login are
            // scattered across six detail views, and auth is a machine-global
            // condition, not a per-section one.
            if app.claudeAuth?.needsSignIn == true { ClaudeSignInBanner(app: app) }
            content
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 600)
        // App-wide mouse selection: descendants inherit unless they opt out with
        // .textSelection(.disabled). Exceptions (Settings tree, card expand headers)
        // opt out locally to keep their click-to-edit / expand tap gestures clean.
        .textSelection(.enabled)
    }

    private var content: some View {
        HStack(spacing: 28) {
            GlassSidebar(selected: $app.selected)
            if app.selected == .home {
                VStack(spacing: 12) {
                    PathBar(app: app)
                    ScrollView {
                        // No horizontal inset: the cards align with the PathBar's edges,
                        // matching every other section's layout.
                        HomeSection(app: app)
                            .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if app.selected == .sessions {
                // Sessions owns its own multi-card layout (list card + transcript card).
                VStack(spacing: 12) {
                    PathBar(app: app)
                    SessionsSection(app: app)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if app.selected == .plans {
                // Plans owns its own multi-card layout (list card + detail card).
                VStack(spacing: 12) {
                    PathBar(app: app)
                    PlansSection(app: app)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if app.selected == .specs {
                // Specs owns its own multi-card layout (list card + detail card).
                VStack(spacing: 12) {
                    PathBar(app: app)
                    SpecsSection(app: app)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if app.selected == .claudeMd {
                // CLAUDE.md owns its own multi-card layout (list card + detail card).
                VStack(spacing: 12) {
                    PathBar(app: app)
                    ClaudeMdSection(app: app)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if app.selected == .memory {
                VStack(spacing: 12) {
                    PathBar(app: app)
                    GlassCard {
                        MemorySection(app: app)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if app.selected == .plugins {
                VStack(spacing: 12) {
                    PathBar(app: app)
                    GlassCard {
                        if app.activePath != nil {
                            PluginsSection(app: app)
                                .padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            ScrollView {
                                PluginsSection(app: app)
                                    .padding(20)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
            } else if app.selected == .appConfig {
                // App Settings owns its own layout (title bar + config cards).
                VStack(spacing: 12) {
                    PathBar(app: app)
                    AppConfigSection(app: app)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(spacing: 12) {
                    PathBar(app: app)
                    GlassCard {
                        sectionView.padding(20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    @ViewBuilder private var sectionView: some View {
        switch app.selected {
        case .home:     EmptyView()
        case .mcp:      MCPSection(app: app)
        case .skills:   SkillsSection(app: app)
        case .commands: CommandsSection(app: app)
        case .agents:   AgentsSection(app: app)
        case .rules:    RulesSection(app: app)
        case .hooks:    HooksSection(app: app)
        case .loops:    LoopsSection(app: app)
        case .worktrees: WorktreesSection(app: app)
        case .tasks:    TasksSection(app: app)
        case .plugins:  PluginsSection(app: app)
        case .settings: SettingsSection(app: app)
        case .sessions: EmptyView()
        case .plans:    EmptyView()
        case .specs:    EmptyView()
        case .claudeMd: EmptyView()
        case .memory:   EmptyView()
        case .appConfig: EmptyView()
        }
    }
}
