import PhotoImportCore
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // Command-line modes, handy for scripting and for checking things without the UI. Neither ever deletes.
        if let path = value(after: "--import-to") { Headless.importTo(path) }
        if let path = value(after: "--similar") { Headless.similar(path, limit: value(after: "--limit").flatMap(Int.init) ?? 5) }
        PhotoImportApp.main()
    }
}

struct PhotoImportApp: App {
    @StateObject private var settings: LibrarySettings
    @StateObject private var phone: PhoneConnection
    @StateObject private var importModel: ImportModel
    @StateObject private var reviewModel: ReviewModel
    @StateObject private var duplicatesModel: DuplicatesModel
    @StateObject private var navigation = Navigation()

    init() {
        let settings = LibrarySettings()
        let phone = PhoneConnection()
        phone.start()
        _settings = StateObject(wrappedValue: settings)
        _phone = StateObject(wrappedValue: phone)
        _importModel = StateObject(wrappedValue: ImportModel(phone: phone, settings: settings))
        _reviewModel = StateObject(wrappedValue: ReviewModel(settings: settings))
        _duplicatesModel = StateObject(wrappedValue: DuplicatesModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup("Photo Import") {
            TabView(selection: $navigation.tab) {
                ImportView(model: importModel, phone: phone, settings: settings) { copied in
                    reviewModel.scan(onlyIncluding: copied)
                    navigation.tab = .similar
                }
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
                .tag(AppTab.importing)
                ReviewView(model: reviewModel, settings: settings)
                    .tabItem { Label("Similar Photos", systemImage: "square.stack.3d.up") }
                    .tag(AppTab.similar)
                DuplicatesView(model: duplicatesModel, settings: settings)
                    .tabItem { Label("Exact Duplicates", systemImage: "doc.on.doc") }
                    .tag(AppTab.duplicates)
            }
            .frame(minWidth: 960, minHeight: 660)
            .task {
                await ScreenshotDriver.runIfRequested(phone: phone, importModel: importModel, reviewModel: reviewModel,
                                                      duplicatesModel: duplicatesModel, navigation: navigation)
            }
        }
    }
}
