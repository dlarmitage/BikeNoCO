import Foundation
import SwiftData

enum PersistenceController {
    static let shared: ModelContainer = {
        do {
            return try makeContainer(inMemory: false)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BikeNoCoSchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: BikeNoCoMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
