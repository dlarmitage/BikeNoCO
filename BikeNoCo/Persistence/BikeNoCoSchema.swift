import Foundation
import SwiftData

/// Schema version 1 — initial `SavedRide` / `SavedRoute` models.
enum BikeNoCoSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [SavedRide.self, SavedRoute.self]
    }
}

/// Migration plan for BikeNoCo SwiftData stores.
///
/// When changing a `@Model` type, add a new `VersionedSchema` (V2, V3, …) and a
/// corresponding stage here. Do not mutate V1 in place.
enum BikeNoCoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BikeNoCoSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // V1 is the baseline — no stages yet.
        []
    }
}
