import SwiftUI
import SwiftData

@main
struct BikeNoCoApp: App {
    private let container = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
