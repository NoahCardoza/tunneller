import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            CredentialSettingsView()
                .tabItem {
                    Label("Credentials", systemImage: "key")
                }
        }
        .frame(width: 480, height: 500)
        .padding(8)
    }
}
