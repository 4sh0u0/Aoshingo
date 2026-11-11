// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct AoshingoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.onboardingCompleted) private var onboardingCompleted = false

    var body: some View {
        ContentView()
            .fullScreenCover(isPresented: Binding(
                get: { !onboardingCompleted },
                set: { _ in }
            )) {
                OnboardingView()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    model.sceneDidEnterBackground()
                case .active:
                    model.sceneDidBecomeActive()
                default:
                    break
                }
            }
    }
}
