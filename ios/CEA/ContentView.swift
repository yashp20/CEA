import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
//            MapsView()
//                .tabItem {
//                    Label("Maps", systemImage: "map.fill")
//                }

            CEAView()
                .tabItem {
                    Label("CEA", systemImage: "circle.hexagongrid.fill")
                }

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
        }
    }
}

#Preview {
    ContentView()
}
