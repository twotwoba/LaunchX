import Foundation

struct SearchConfig: Codable, Equatable {
    /// Default standard scopes for documents
    static let defaultDocumentScopes: [String] = [
        NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first ?? "",
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? "",
        NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? "",
    ]

    /// Default standard scopes for apps
    static let defaultAppScopes: [String] = [
        "/Applications",
        "/System/Applications",
    ]

    /// Default excluded folder names
    static let defaultExcludedFolderNames: [String] = [
        "node_modules",
        "dist",
    ]

    /// Default excluded file extensions
    static let defaultExcludedExtensions: [String] = []

    /// Default excluded paths
    static let defaultExcludedPaths: [String] = []

    /// Paths to include in document search
    var documentScopes: [String]

    /// Paths to include in app search
    var appScopes: [String]

    /// Specific full paths to exclude
    var excludedPaths: [String]

    /// File extensions to exclude (e.g., "log", "tmp")
    var excludedExtensions: [String]

    /// Folder names to exclude globally (e.g., node_modules)
    var excludedFolderNames: [String]

    init(
        documentScopes: [String] = SearchConfig.defaultDocumentScopes,
        appScopes: [String] = SearchConfig.defaultAppScopes,
        excludedPaths: [String] = SearchConfig.defaultExcludedPaths,
        excludedExtensions: [String] = SearchConfig.defaultExcludedExtensions,
        excludedFolderNames: [String] = SearchConfig.defaultExcludedFolderNames
    ) {
        self.documentScopes = documentScopes
        self.appScopes = appScopes
        self.excludedPaths = excludedPaths
        self.excludedExtensions = excludedExtensions
        self.excludedFolderNames = excludedFolderNames
    }

    /// Combined search scopes for backward compatibility
    var searchScopes: [String] {
        return appScopes + documentScopes
    }

    /// Combined excluded names for backward compatibility
    var excludedNames: [String] {
        return excludedFolderNames
    }

    // MARK: - Persistence

    private static let configKey = "SearchConfig"

    static func load() -> SearchConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
            let config = try? JSONDecoder().decode(SearchConfig.self, from: data)
        else {
            return SearchConfig()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: SearchConfig.configKey)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: configKey)
    }
}
