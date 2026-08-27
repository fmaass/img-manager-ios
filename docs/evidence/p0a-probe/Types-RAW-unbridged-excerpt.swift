// EXCERPT — RAW vendored schema (bridge NOT applied) -- 29/29 target properties DROPPED
// Extracted 2026-08-27 from a real `swift build` run on merkur (DEVELOPER_DIR
// exported), NOT hand-written. Only the 11 struct definitions holding the 29 tracked
// component-schema anyOf-nullable properties are kept; the full generated file is
// 5500-6300 lines and not worth committing whole.

// --- ApiHealthResponse ---
        /// - Remark: Generated from `#/components/schemas/ApiHealthResponse`.
        public struct ApiHealthResponse: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/ApiHealthResponse/db`.
            public var db: Swift.String
            /// - Remark: Generated from `#/components/schemas/ApiHealthResponse/status`.
            public var status: Swift.String
            /// - Remark: Generated from `#/components/schemas/ApiHealthResponse/version`.
            public var version: Swift.String
            /// Creates a new `ApiHealthResponse`.
            ///
            /// - Parameters:
            ///   - db:
            ///   - status:
            ///   - version:
            public init(
                db: Swift.String,
                status: Swift.String,
                version: Swift.String
            ) {
                self.db = db
                self.status = status
                self.version = version
            }
            public enum CodingKeys: String, CodingKey {
                case db
                case status
                case version
            }
        }

// --- FolderNode ---
        /// - Remark: Generated from `#/components/schemas/FolderNode`.
        public struct FolderNode: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/FolderNode/descendant_image_count`.
            public var descendantImageCount: Swift.Int?
            /// - Remark: Generated from `#/components/schemas/FolderNode/id`.
            public var id: Swift.Int
            /// - Remark: Generated from `#/components/schemas/FolderNode/image_count`.
            public var imageCount: Swift.Int?
            /// - Remark: Generated from `#/components/schemas/FolderNode/kind`.
            public var kind: Swift.String
            /// - Remark: Generated from `#/components/schemas/FolderNode/name`.
            public var name: Swift.String
            /// - Remark: Generated from `#/components/schemas/FolderNode/path`.
            public var path: Swift.String
            /// Creates a new `FolderNode`.
            ///
            /// - Parameters:
            ///   - descendantImageCount:
            ///   - id:
            ///   - imageCount:
            ///   - kind:
            ///   - name:
            ///   - path:
            public init(
                descendantImageCount: Swift.Int? = nil,
                id: Swift.Int,
                imageCount: Swift.Int? = nil,
                kind: Swift.String,
                name: Swift.String,
                path: Swift.String
            ) {
                self.descendantImageCount = descendantImageCount
                self.id = id
                self.imageCount = imageCount
                self.kind = kind
                self.name = name
                self.path = path
            }
            public enum CodingKeys: String, CodingKey {
                case descendantImageCount = "descendant_image_count"
                case id
                case imageCount = "image_count"
                case kind
                case name
                case path
            }
        }

// --- ImageDetail ---
        /// - Remark: Generated from `#/components/schemas/ImageDetail`.
        public struct ImageDetail: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/ImageDetail/exif`.
            public struct ExifPayload: Codable, Hashable, Sendable {
                /// - Remark: Generated from `#/components/schemas/ImageDetail/exif/additionalProperties`.
                public struct AdditionalPropertiesPayload: Codable, Hashable, Sendable {
                    /// - Remark: Generated from `#/components/schemas/ImageDetail/exif/additionalProperties/value1`.
                    public var value1: Swift.String?
                    /// - Remark: Generated from `#/components/schemas/ImageDetail/exif/additionalProperties/value2`.
                    public var value2: Swift.Int?
                    /// - Remark: Generated from `#/components/schemas/ImageDetail/exif/additionalProperties/value3`.
                    public var value3: Swift.Double?
                    /// Creates a new `AdditionalPropertiesPayload`.
                    ///
                    /// - Parameters:
                    ///   - value1:
                    ///   - value2:
                    ///   - value3:
                    public init(
                        value1: Swift.String? = nil,
                        value2: Swift.Int? = nil,
                        value3: Swift.Double? = nil
                    ) {
                        self.value1 = value1
                        self.value2 = value2
                        self.value3 = value3
                    }
                    public init(from decoder: any Swift.Decoder) throws {
                        var errors: [any Swift.Error] = []
                        do {
                            self.value1 = try decoder.decodeFromSingleValueContainer()
                        } catch {
                            errors.append(error)
                        }
                        do {
                            self.value2 = try decoder.decodeFromSingleValueContainer()
                        } catch {
                            errors.append(error)
                        }
                        do {
                            self.value3 = try decoder.decodeFromSingleValueContainer()
                        } catch {
                            errors.append(error)
                        }
                        try Swift.DecodingError.verifyAtLeastOneSchemaIsNotNil(
                            [
                                self.value1,
                                self.value2,
                                self.value3
                            ],
                            type: Self.self,
                            codingPath: decoder.codingPath,
                            errors: errors
                        )
                    }
                    public func encode(to encoder: any Swift.Encoder) throws {
                        try encoder.encodeFirstNonNilValueToSingleValueContainer([
                            self.value1,
                            self.value2,
                            self.value3
                        ])
                    }
                }
                /// A container of undocumented properties.
                public var additionalProperties: [String: Components.Schemas.ImageDetail.ExifPayload.AdditionalPropertiesPayload]
                /// Creates a new `ExifPayload`.
                ///
                /// - Parameters:
                ///   - additionalProperties: A container of undocumented properties.
                public init(additionalProperties: [String: Components.Schemas.ImageDetail.ExifPayload.AdditionalPropertiesPayload] = .init()) {
                    self.additionalProperties = additionalProperties
                }
                public init(from decoder: any Swift.Decoder) throws {
                    additionalProperties = try decoder.decodeAdditionalProperties(knownKeys: [])
                }
                public func encode(to encoder: any Swift.Encoder) throws {
                    try encoder.encodeAdditionalProperties(additionalProperties)
                }
            }
            /// - Remark: Generated from `#/components/schemas/ImageDetail/exif`.
            public var exif: Components.Schemas.ImageDetail.ExifPayload?
            /// - Remark: Generated from `#/components/schemas/ImageDetail/ext`.
            public var ext: Swift.String
            /// - Remark: Generated from `#/components/schemas/ImageDetail/filename`.
            public var filename: Swift.String
            /// - Remark: Generated from `#/components/schemas/ImageDetail/folder_id`.
            public var folderId: Swift.Int
            /// - Remark: Generated from `#/components/schemas/ImageDetail/has_edit`.
            public var hasEdit: Swift.Bool?
            /// - Remark: Generated from `#/components/schemas/ImageDetail/id`.
            public var id: Swift.Int
            /// - Remark: Generated from `#/components/schemas/ImageDetail/lightroom`.
            public var lightroom: Components.Schemas.LightroomMeta
            /// - Remark: Generated from `#/components/schemas/ImageDetail/mark`.
            public var mark: Components.Schemas.MarkView
            /// - Remark: Generated from `#/components/schemas/ImageDetail/missing`.
            public var missing: Swift.Bool?
            /// - Remark: Generated from `#/components/schemas/ImageDetail/proxies`.
            public struct ProxiesPayload: Codable, Hashable, Sendable {
                /// A container of undocumented properties.
                public var additionalProperties: [String: Components.Schemas.ProxyState]
                /// Creates a new `ProxiesPayload`.
                ///
                /// - Parameters:
                ///   - additionalProperties: A container of undocumented properties.
                public init(additionalProperties: [String: Components.Schemas.ProxyState] = .init()) {
                    self.additionalProperties = additionalProperties
                }
                public init(from decoder: any Swift.Decoder) throws {
                    additionalProperties = try decoder.decodeAdditionalProperties(knownKeys: [])
                }
                public func encode(to encoder: any Swift.Encoder) throws {
                    try encoder.encodeAdditionalProperties(additionalProperties)
                }
            }
            /// - Remark: Generated from `#/components/schemas/ImageDetail/proxies`.
            public var proxies: Components.Schemas.ImageDetail.ProxiesPayload
            /// - Remark: Generated from `#/components/schemas/ImageDetail/renditions`.
            public var renditions: [Components.Schemas.RenditionChip]?
            /// - Remark: Generated from `#/components/schemas/ImageDetail/source_tier`.
            public var sourceTier: Swift.String

// --- ImagePage ---
        /// - Remark: Generated from `#/components/schemas/ImagePage`.
        public struct ImagePage: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/ImagePage/items`.
            public var items: [Components.Schemas.ImageSummary]
            /// - Remark: Generated from `#/components/schemas/ImagePage/limit`.
            public var limit: Swift.Int
            /// Creates a new `ImagePage`.
            ///
            /// - Parameters:
            ///   - items:
            ///   - limit:
            public init(
                items: [Components.Schemas.ImageSummary],
                limit: Swift.Int
            ) {
                self.items = items
                self.limit = limit
            }
            public enum CodingKeys: String, CodingKey {
                case items
                case limit
            }
        }

// --- ImageSummary ---
        /// - Remark: Generated from `#/components/schemas/ImageSummary`.
        public struct ImageSummary: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/ImageSummary/ext`.
            public var ext: Swift.String
            /// - Remark: Generated from `#/components/schemas/ImageSummary/filename`.
            public var filename: Swift.String
            /// - Remark: Generated from `#/components/schemas/ImageSummary/folder_id`.
            public var folderId: Swift.Int
            /// - Remark: Generated from `#/components/schemas/ImageSummary/has_edit`.
            public var hasEdit: Swift.Bool?
            /// - Remark: Generated from `#/components/schemas/ImageSummary/id`.
            public var id: Swift.Int
            /// - Remark: Generated from `#/components/schemas/ImageSummary/lightroom`.
            public var lightroom: Components.Schemas.LightroomMeta
            /// - Remark: Generated from `#/components/schemas/ImageSummary/mark`.
            public var mark: Components.Schemas.MarkView
            /// - Remark: Generated from `#/components/schemas/ImageSummary/missing`.
            public var missing: Swift.Bool?
            /// - Remark: Generated from `#/components/schemas/ImageSummary/proxies`.
            public struct ProxiesPayload: Codable, Hashable, Sendable {
                /// A container of undocumented properties.
                public var additionalProperties: [String: Components.Schemas.ProxyState]
                /// Creates a new `ProxiesPayload`.
                ///
                /// - Parameters:
                ///   - additionalProperties: A container of undocumented properties.
                public init(additionalProperties: [String: Components.Schemas.ProxyState] = .init()) {
                    self.additionalProperties = additionalProperties
                }
                public init(from decoder: any Swift.Decoder) throws {
                    additionalProperties = try decoder.decodeAdditionalProperties(knownKeys: [])
                }
                public func encode(to encoder: any Swift.Encoder) throws {
                    try encoder.encodeAdditionalProperties(additionalProperties)
                }
            }
            /// - Remark: Generated from `#/components/schemas/ImageSummary/proxies`.
            public var proxies: Components.Schemas.ImageSummary.ProxiesPayload
            /// - Remark: Generated from `#/components/schemas/ImageSummary/source_tier`.
            public var sourceTier: Swift.String
            /// Creates a new `ImageSummary`.
            ///
            /// - Parameters:
            ///   - ext:
            ///   - filename:
            ///   - folderId:
            ///   - hasEdit:
            ///   - id:
            ///   - lightroom:
            ///   - mark:
            ///   - missing:
            ///   - proxies:
            ///   - sourceTier:
            public init(
                ext: Swift.String,
                filename: Swift.String,
                folderId: Swift.Int,
                hasEdit: Swift.Bool? = nil,
                id: Swift.Int,
                lightroom: Components.Schemas.LightroomMeta,
                mark: Components.Schemas.MarkView,
                missing: Swift.Bool? = nil,
                proxies: Components.Schemas.ImageSummary.ProxiesPayload,
                sourceTier: Swift.String
            ) {
                self.ext = ext
                self.filename = filename
                self.folderId = folderId
                self.hasEdit = hasEdit
                self.id = id
                self.lightroom = lightroom
                self.mark = mark
                self.missing = missing
                self.proxies = proxies
                self.sourceTier = sourceTier
            }
            public enum CodingKeys: String, CodingKey {
                case ext
                case filename
                case folderId = "folder_id"
                case hasEdit = "has_edit"
                case id
                case lightroom
                case mark
                case missing
                case proxies
                case sourceTier = "source_tier"
            }
        }

// --- LightroomMeta ---
        /// - Remark: Generated from `#/components/schemas/LightroomMeta`.
        public struct LightroomMeta: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/LightroomMeta/keywords`.
            public var keywords: [Swift.String]?
            /// - Remark: Generated from `#/components/schemas/LightroomMeta/sidecar_present`.
            public var sidecarPresent: Swift.Bool
            /// Creates a new `LightroomMeta`.
            ///
            /// - Parameters:
            ///   - keywords:
            ///   - sidecarPresent:
            public init(
                keywords: [Swift.String]? = nil,
                sidecarPresent: Swift.Bool
            ) {
                self.keywords = keywords
                self.sidecarPresent = sidecarPresent
            }
            public enum CodingKeys: String, CodingKey {
                case keywords
                case sidecarPresent = "sidecar_present"
            }
        }

// --- MaintenanceRunView ---
        /// - Remark: Generated from `#/components/schemas/MaintenanceRunView`.
        public struct MaintenanceRunView: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/MaintenanceRunView/counters`.
            public var counters: Components.Schemas.RunCounters?
            /// - Remark: Generated from `#/components/schemas/MaintenanceRunView/id`.
            public var id: Swift.Int
            /// - Remark: Generated from `#/components/schemas/MaintenanceRunView/started_at`.
            public var startedAt: Foundation.Date
            /// - Remark: Generated from `#/components/schemas/MaintenanceRunView/state`.
            public var state: Swift.String
            /// - Remark: Generated from `#/components/schemas/MaintenanceRunView/trigger`.
            public var trigger: Swift.String
            /// Creates a new `MaintenanceRunView`.
            ///
            /// - Parameters:
            ///   - counters:
            ///   - id:
            ///   - startedAt:
            ///   - state:
            ///   - trigger:
            public init(
                counters: Components.Schemas.RunCounters? = nil,
                id: Swift.Int,
                startedAt: Foundation.Date,
                state: Swift.String,
                trigger: Swift.String
            ) {
                self.counters = counters
                self.id = id
                self.startedAt = startedAt
                self.state = state
                self.trigger = trigger
            }
            public enum CodingKeys: String, CodingKey {
                case counters
                case id
                case startedAt = "started_at"
                case state
                case trigger
            }
        }

// --- MaintenanceStatus ---
        /// - Remark: Generated from `#/components/schemas/MaintenanceStatus`.
        public struct MaintenanceStatus: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/MaintenanceStatus/enabled`.
            public var enabled: Swift.Bool
            /// - Remark: Generated from `#/components/schemas/MaintenanceStatus/executor_lock`.
            @frozen public enum ExecutorLockPayload: String, Codable, Hashable, Sendable, CaseIterable {
                case free = "free"
                case held = "held"
                case unavailable = "unavailable"
                case unknown = "unknown"
            }
            /// - Remark: Generated from `#/components/schemas/MaintenanceStatus/executor_lock`.
            public var executorLock: Components.Schemas.MaintenanceStatus.ExecutorLockPayload?
            /// Creates a new `MaintenanceStatus`.
            ///
            /// - Parameters:
            ///   - enabled:
            ///   - executorLock:
            public init(
                enabled: Swift.Bool,
                executorLock: Components.Schemas.MaintenanceStatus.ExecutorLockPayload? = nil
            ) {
                self.enabled = enabled
                self.executorLock = executorLock
            }
            public enum CodingKeys: String, CodingKey {
                case enabled
                case executorLock = "executor_lock"
            }
        }

// --- ProxyState ---
        /// - Remark: Generated from `#/components/schemas/ProxyState`.
        public struct ProxyState: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/ProxyState/verdict`.
            public var verdict: Components.Schemas.Verdict
            /// Creates a new `ProxyState`.
            ///
            /// - Parameters:
            ///   - verdict:
            public init(verdict: Components.Schemas.Verdict) {
                self.verdict = verdict
            }
            public enum CodingKeys: String, CodingKey {
                case verdict
            }
        }

// --- StatusResponse ---
        /// - Remark: Generated from `#/components/schemas/StatusResponse`.
        public struct StatusResponse: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/StatusResponse/coverage`.
            public var coverage: Components.Schemas.Coverage
            /// - Remark: Generated from `#/components/schemas/StatusResponse/maintenance`.
            public var maintenance: Components.Schemas.MaintenanceStatus
            /// - Remark: Generated from `#/components/schemas/StatusResponse/runs`.
            public var runs: [Components.Schemas.MaintenanceRunView]
            /// - Remark: Generated from `#/components/schemas/StatusResponse/stores`.
            public var stores: [Components.Schemas.StoreMountHealth]?
            /// Creates a new `StatusResponse`.
            ///
            /// - Parameters:
            ///   - coverage:
            ///   - maintenance:
            ///   - runs:
            ///   - stores:
            public init(
                coverage: Components.Schemas.Coverage,
                maintenance: Components.Schemas.MaintenanceStatus,
                runs: [Components.Schemas.MaintenanceRunView],
                stores: [Components.Schemas.StoreMountHealth]? = nil
            ) {
                self.coverage = coverage
                self.maintenance = maintenance
                self.runs = runs
                self.stores = stores
            }
            public enum CodingKeys: String, CodingKey {
                case coverage
                case maintenance
                case runs
                case stores
            }
        }

// --- StoreMountHealth ---
        /// - Remark: Generated from `#/components/schemas/StoreMountHealth`.
        public struct StoreMountHealth: Codable, Hashable, Sendable {
            /// - Remark: Generated from `#/components/schemas/StoreMountHealth/health`.
            @frozen public enum HealthPayload: String, Codable, Hashable, Sendable, CaseIterable {
                case mounted = "mounted"
                case unknown = "unknown"
                case absent = "absent"
            }
            /// - Remark: Generated from `#/components/schemas/StoreMountHealth/health`.
            public var health: Components.Schemas.StoreMountHealth.HealthPayload
            /// - Remark: Generated from `#/components/schemas/StoreMountHealth/indexed`.
            public var indexed: Swift.Bool?
            /// - Remark: Generated from `#/components/schemas/StoreMountHealth/store`.
            public var store: Swift.String
            /// Creates a new `StoreMountHealth`.
            ///
            /// - Parameters:
            ///   - health:
            ///   - indexed:
            ///   - store:
            public init(
                health: Components.Schemas.StoreMountHealth.HealthPayload,
                indexed: Swift.Bool? = nil,
                store: Swift.String
            ) {
                self.health = health
                self.indexed = indexed
                self.store = store
            }
            public enum CodingKeys: String, CodingKey {
                case health
                case indexed
                case store
            }
        }
