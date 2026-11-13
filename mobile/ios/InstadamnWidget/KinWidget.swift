import WidgetKit
import SwiftUI
import AppIntents
import ImageIO

private func currentStore() -> WidgetStore? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetStore.groupId).map { WidgetStore(container: $0) }
}

struct FeedEntry: TimelineEntry {
    let date: Date
    let imageData: Data?
    let posterName: String?
    let sourceName: String
    let postURL: URL?
    static func empty(_ date: Date = Date(), source: String = "Your friends") -> FeedEntry {
        FeedEntry(date: date, imageData: nil, posterName: nil, sourceName: source, postURL: nil)
    }
}

@available(iOS 17.0, *)
struct PhotoSource: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Friend or List"
    static var defaultQuery = PhotoSourceQuery()
    let id: String
    let name: String
    let kind: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind == "list" ? "List" : "Friend")")
    }
    init(_ source: WidgetSource) { id = source.selectionId; name = source.name; kind = source.kind }
    init(unavailable id: String) { self.id = id; name = "Open A/SIDE to choose again"; kind = "unavailable" }
}

@available(iOS 17.0, *)
struct PhotoSourceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PhotoSource] {
        let available = try await suggestedEntities()
        return identifiers.map { id in available.first(where: { $0.id == id }) ?? PhotoSource(unavailable: id) }
    }
    func suggestedEntities() async throws -> [PhotoSource] {
        guard let store = currentStore(), let session = store.session else { return [] }
        return store.sources(for: session).map(PhotoSource.init)
    }
}

@available(iOS 17.0, *)
struct PhotoWidgetIntent: WidgetConfigurationIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "Your people"
    static var description = IntentDescription("Choose a friend or one of your personal Lists. Leave this empty for all friends.")
    @Parameter(title: "Friend or List") var source: PhotoSource?
    static var parameterSummary: some ParameterSummary { Summary("Photos from \(\.$source)") }
}

private enum PhotoTimeline {
    static func load(selectionId: String?) async -> Timeline<FeedEntry> {
        let now = Date()
        let retry = now.addingTimeInterval(30 * 60)
        func empty(_ name: String = "Your friends") -> Timeline<FeedEntry> {
            Timeline(entries: [.empty(now, source: name)], policy: .after(retry))
        }
        guard let store = currentStore(), let session = store.session else { return empty() }
        let source: WidgetSource?
        if let selectionId {
            // A removed choice or an old account's selection never falls back
            // to somebody else's photos.
            guard let selected = store.sources(for: session).first(where: { $0.selectionId == selectionId }) else { return empty("Open A/SIDE to choose again") }
            source = selected
        } else { source = nil }
        let name = source?.name ?? "Your friends"
        guard let url = session.endpoint(source: source) else { return empty(name) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await network.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  store.session == session,
                  let photo = try JSONDecoder().decode(WidgetResponse.self, from: data).post,
                  photo.user_id != session.userId, let imageURL = URL(string: photo.image_url),
                  imageURL.scheme == "https" || (imageURL.scheme == "http" && ["localhost", "127.0.0.1"].contains(imageURL.host ?? "")) else { return empty(name) }
            // Stream with a fixed cap and downsample before decoding a full-size
            // photo. Never attach the API credential to the media request.
            let (bytes, imageResponse) = try await network.bytes(from: imageURL)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { return empty(name) }
            var encoded = Data()
            for try await byte in bytes {
                if encoded.count >= 10 * 1024 * 1024 { return empty(name) }
                encoded.append(byte)
            }
            guard store.session == session,
                  let imageSource = CGImageSourceCreateWithData(encoded as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary),
                  let image = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8),
                  let link = photo.deepLink(ownerId: session.userId) else { return empty(name) }
            let expiration = photo.expiration(now: now)
            guard expiration > Date() else { return empty(name) }
            let entry = FeedEntry(date: now, imageData: image, posterName: photo.display_name, sourceName: name, postURL: link)
            // Clear the visible photo at expiry even if the next refresh fails.
            return Timeline(entries: [entry, .empty(expiration, source: name)], policy: .after(min(retry, expiration)))
        } catch { return empty(name) }
    }
}

struct KinWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry { .empty() }
    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) { completion(.empty()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        Task { completion(await PhotoTimeline.load(selectionId: nil)) }
    }
}

@available(iOS 17.0, *)
struct ConfigurablePhotoProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FeedEntry { .empty() }
    func snapshot(for configuration: PhotoWidgetIntent, in context: Context) async -> FeedEntry { .empty(source: configuration.source?.name ?? "Your friends") }
    func timeline(for configuration: PhotoWidgetIntent, in context: Context) async -> Timeline<FeedEntry> {
        await PhotoTimeline.load(selectionId: configuration.source?.id)
    }
}

struct KinWidgetEntryView: View {
    let entry: FeedEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let data = entry.imageData, let image = UIImage(data: data) {
                GeometryReader { geo in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.posterName ?? "").font(.headline).lineLimit(2)
                    if entry.sourceName != "Your friends" && entry.sourceName != entry.posterName {
                        Text(entry.sourceName).font(.caption).lineLimit(1)
                    }
                }.foregroundStyle(.white).padding(14)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2)
                    Text(entry.sourceName).font(.headline).lineLimit(2)
                    Text("Open A/SIDE").font(.caption)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding().foregroundStyle(.secondary)
            }
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.imageData != nil ? "Photo from \(entry.posterName ?? "a friend"). Open this post in A/SIDE." : "\(entry.sourceName). Open A/SIDE to refresh or set up your widget.")
        .widgetURL(entry.postURL ?? URL(string: "aside://widgets"))
    }
}

@available(iOS 17.0, *)
struct KinWidget: Widget {
    let kind = "KinWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PhotoWidgetIntent.self, provider: ConfigurablePhotoProvider()) { entry in
            KinWidgetEntryView(entry: entry).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Your people")
        .description("Photos from a friend or personal List. Tap to open the post.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct LegacyPhotoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KinWidget", provider: KinWidgetProvider()) { KinWidgetEntryView(entry: $0) }
            .configurationDisplayName("Latest Photo")
            .description("Photos from your friends. Open A/SIDE to refresh.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct KinWidgetBundle: WidgetBundle {
    var body: some Widget { availableWidget() }
    private func availableWidget() -> some Widget {
        let selected: any Widget
        if #available(iOS 17.0, *) { selected = KinWidget() } else { selected = LegacyPhotoWidget() }
        return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(selected))
    }
}
