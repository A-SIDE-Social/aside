import WidgetKit
import SwiftUI

private let appGroupId = "group.com.lab1908.instadamn"

// MARK: - Entry

struct FeedEntry: TimelineEntry {
    let date: Date
    let imageData: Data?
    let posterName: String?
}

// MARK: - Provider

struct KinWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: Date(), imageData: nil, posterName: "Friend")
    }

    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        let entry = loadEntry()
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> FeedEntry {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return FeedEntry(date: Date(), imageData: nil, posterName: nil)
        }

        var thumbData: Data? = nil
        var posterName: String? = nil

        if let fileData = try? Data(contentsOf: container.appendingPathComponent("widget_image.jpg")),
           let original = UIImage(data: fileData) {
            let maxDim: CGFloat = 200
            let scale = min(maxDim / original.size.width, maxDim / original.size.height, 1.0)
            let newSize = CGSize(width: original.size.width * scale, height: original.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            thumbData = renderer.jpegData(withCompressionQuality: 0.7) { _ in
                original.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }

        if let meta = try? Data(contentsOf: container.appendingPathComponent("widget_meta.json")),
           let json = try? JSONSerialization.jsonObject(with: meta) as? [String: String] {
            posterName = json["poster_name"]
        }

        return FeedEntry(date: Date(), imageData: thumbData, posterName: posterName)
    }
}

// MARK: - View

struct KinWidgetEntryView: View {
    var entry: FeedEntry

    var body: some View {
        if entry.imageData != nil {
            GeometryReader { geo in
                ZStack {
                    if let data = entry.imageData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }

                    VStack {
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 60)
                    }

                    if let name = entry.posterName, !name.isEmpty {
                        VStack {
                            Spacer()
                            HStack {
                                Text(name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                                Spacer()
                            }
                        }
                        .padding(12)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Open A/SIDE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

// MARK: - Widget

struct KinWidget: Widget {
    let kind = "KinWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KinWidgetProvider()) { entry in
            if #available(iOSApplicationExtension 17.0, *) {
                KinWidgetEntryView(entry: entry)
                    .containerBackground(.black, for: .widget)
            } else {
                KinWidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("Latest Photo")
        .description("See the latest photo from your friends.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct KinWidgetBundle: WidgetBundle {
    var body: some Widget {
        KinWidget()
    }
}
