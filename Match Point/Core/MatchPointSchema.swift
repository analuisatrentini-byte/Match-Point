import Foundation
import SwiftData

/// Versioned schema scaffolding for SwiftData. With only V1 in flight today
/// the migration plan has no stages — but every future model change (rename,
/// new mandatory property, relationship rule flip) should bump the version
/// and register the appropriate migration stage instead of relying on
/// SwiftData's implicit lightweight inference, which is best-effort and has
/// no rollback path when it gets it wrong.
///
/// # Checklist when bumping the schema
///
/// 1. Copy the current model definitions into a new `enum
///    MatchPointSchemaVn: VersionedSchema` namespace (the snapshot of
///    "what V(n-1) looked like at the time of the bump"). The live `@Model`
///    classes are free to change to the new shape after.
/// 2. Bump `versionIdentifier`.
/// 3. Add the new schema to `MatchPointMigrationPlan.schemas`.
/// 4. **Append a stage** to `MatchPointMigrationPlan.stages` describing the
///    transition — empty `stages` is only valid while a single schema exists.
/// 5. Test the migration with a fixture store seeded under the previous
///    schema (`@Test func v1ToV2Migration() throws`).
///
/// Example for adding V2 later:
///
///     enum MatchPointSchemaV2: VersionedSchema {
///         static var versionIdentifier = Schema.Version(2, 0, 0)
///         static var models: [any PersistentModel.Type] { [...new types...] }
///     }
///
///     extension MatchPointMigrationPlan {
///         static let v1ToV2 = MigrationStage.lightweight(
///             fromVersion: MatchPointSchemaV1.self,
///             toVersion: MatchPointSchemaV2.self
///         )
///     }
///
/// Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` instead of
/// `.lightweight` whenever a stage needs to backfill a non-optional property
/// or transform stored data.

enum MatchPointSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Player.self,
            Tournament.self,
            TennisMatch.self,
            RankingEntry.self,
            UserProfile.self,
            PointBet.self,
            SocialPost.self,
            MatchPoll.self
        ]
    }
}

enum MatchPointMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MatchPointSchemaV1.self]
    }

    /// One `MigrationStage` per adjacent transition. Empty is only valid while
    /// `schemas.count == 1`. The contract test
    /// `migrationPlanHasOneStagePerSchemaTransition()` in Match_PointTests
    /// enforces this invariant — if the assertion trips after you add a
    /// `MatchPointSchemaV2`, append the matching stage here.
    static var stages: [MigrationStage] {
        []
    }
}
