import SwiftUI
import MapKit

struct MapsView: View {
    @State private var searchText = ""
    @State private var position = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Map(position: $position)
                    .ignoresSafeArea()

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Where to?", text: $searchText)
                    if !searchText.isEmpty {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .navigationTitle("Maps")
            .navigationBarHidden(true)
        }
    }
}

#Preview {
    MapsView()
}
