import Foundation

enum FileCategory: String, Sendable, CaseIterable {
    case folder, image, video, audio, document, text, archive, androidPackage, other

    init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "dng", "raw", "tiff":
            self = .image
        case "mp4", "mov", "mkv", "avi", "3gp", "webm", "m4v":
            self = .video
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "amr":
            self = .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "hwp", "hwpx", "key", "pages", "numbers":
            self = .document
        case "txt", "md", "csv", "json", "xml", "log", "rtf":
            self = .text
        case "zip", "rar", "7z", "tar", "gz", "tgz":
            self = .archive
        case "apk", "apks", "xapk":
            self = .androidPackage
        default:
            self = .other
        }
    }

    var symbolName: String {
        switch self {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .document: "doc.richtext"
        case .text: "doc.plaintext"
        case .archive: "doc.zipper"
        case .androidPackage: "shippingbox"
        case .other: "doc"
        }
    }

    var localizationKey: String { "fileKind.\(rawValue)" }

    /// Formats Quick Look can show after the file is copied to the Mac.
    static let previewableExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "dng",
        "mp4", "mov", "m4v", "3gp",
        "mp3", "m4a", "aac", "wav", "flac", "aiff",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf",
        "txt", "md", "csv", "json", "xml", "log", "html",
    ]

    static func isPreviewable(fileName: String) -> Bool {
        previewableExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }
}

struct FileItem: Identifiable, Hashable, Sendable {
    let id: FileItemID
    let name: String
    let isFolder: Bool
    let size: UInt64?
    let modified: Date?

    var category: FileCategory { isFolder ? .folder : FileCategory(fileName: name) }

    // Sort keys used by Table's KeyPathComparator; nil values sort first.
    var sizeSortKey: UInt64 { isFolder ? 0 : (size ?? 0) }
    var modifiedSortKey: Date { modified ?? .distantPast }
    var kindSortKey: String { category.rawValue }
}
