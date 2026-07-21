import AppKit

/// One editor tab: a background raster + a re-editable annotation layer.
@MainActor
final class EditorDocument {
    var background: CGImage
    var annotations: [Annotation] = []
    var fileURL: URL?              // .fscx or exported image path
    var title: String?            // auto-assigned name for untitled tabs (未命名 N)
    var isDirty = false
    var stepCounter = 1            // auto-increment for step-number objects
    let undoManager = UndoManager()

    var displayName: String {
        fileURL?.lastPathComponent ?? title ?? Loc.t("未命名", "Untitled")
    }

    var pixelSize: CGSize { CGSize(width: background.width, height: background.height) }

    init(background: CGImage, fileURL: URL? = nil) {
        self.background = background
        self.fileURL = fileURL
        undoManager.levelsOfUndo = 30
    }

    /// What the editor canvas shows and what exports produce.
    var composited: CGImage {
        Compositor.flatten(background: background, annotations: annotations)
    }

    // MARK: undoable mutations

    /// Replace the raster (crop/rotate/effects…). Annotations are baked in
    /// first when present, so vector objects never desync from the pixels.
    func applyRasterOp(_ name: String, _ op: (CGImage) -> CGImage) {
        bakeAnnotationsIfNeeded()
        let old = background
        let oldAnnotations = annotations
        background = op(background)
        isDirty = true
        undoManager.registerUndo(withTarget: self) { doc in
            doc.replaceState(background: old, annotations: oldAnnotations, actionName: name)
        }
        undoManager.setActionName(name)
    }

    func setAnnotations(_ new: [Annotation], actionName: String) {
        let old = annotations
        annotations = new
        isDirty = true
        undoManager.registerUndo(withTarget: self) { doc in
            doc.setAnnotations(old, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func replaceState(background: CGImage, annotations: [Annotation], actionName: String) {
        let curBG = self.background
        let curAnn = self.annotations
        self.background = background
        self.annotations = annotations
        isDirty = true
        undoManager.registerUndo(withTarget: self) { doc in
            doc.replaceState(background: curBG, annotations: curAnn, actionName: actionName)
        }
        NotificationCenter.default.post(name: .editorDocumentChanged, object: self)
    }

    func bakeAnnotationsIfNeeded() {
        guard !annotations.isEmpty else { return }
        background = Compositor.flatten(background: background, annotations: annotations)
        annotations = []
    }
}

extension Notification.Name {
    static let editorDocumentChanged = Notification.Name("editorDocumentChanged")
}

// MARK: - .fscx (single-file zip: background.png + annotations.json + meta.json + thumbnail.png)

enum FSCXError: LocalizedError {
    case zipFailed(String)
    case badArchive

    var errorDescription: String? {
        switch self {
        case .zipFailed(let s): return Loc.t("打包 .fscx 失败：\(s)", "Failed to package .fscx: \(s)")
        case .badArchive: return Loc.t("不是有效的 .fscx 文件", "Not a valid .fscx file")
        }
    }
}

enum FSCX {
    struct Meta: Codable {
        var app = "FSCapture"
        var version = 1
        var width: Int
        var height: Int
        var created: Date
        var stepCounter: Int
    }

    @MainActor
    static func save(_ doc: EditorDocument, to url: URL) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fscx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let bgData = Export.encode(doc.background, format: .png) else {
            throw FSCXError.zipFailed(Loc.t("PNG 编码失败", "PNG encoding failed"))
        }
        try bgData.write(to: tmp.appendingPathComponent("background.png"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(doc.annotations).write(to: tmp.appendingPathComponent("annotations.json"))
        let meta = Meta(width: doc.background.width, height: doc.background.height,
                        created: Date(), stepCounter: doc.stepCounter)
        try encoder.encode(meta).write(to: tmp.appendingPathComponent("meta.json"))

        let thumb = ImageOps.resize(doc.composited, to: thumbSize(for: doc.pixelSize))
        if let thumbData = Export.encode(thumb, format: .png) {
            try thumbData.write(to: tmp.appendingPathComponent("thumbnail.png"))
        }

        // zip -j: flat archive at the destination. Write to temp zip then move.
        let tmpZip = tmp.appendingPathComponent("out.fscx")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = tmp
        proc.arguments = ["-q", "-j", tmpZip.path,
                          "background.png", "annotations.json", "meta.json", "thumbnail.png"]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FSCXError.zipFailed(msg)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpZip, to: url)
    }

    @MainActor
    static func load(from url: URL) throws -> EditorDocument {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fscx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", "-o", url.path, "-d", tmp.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw FSCXError.badArchive }

        guard let bgImage = NSImage(contentsOf: tmp.appendingPathComponent("background.png")),
              let bg = bgImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FSCXError.badArchive
        }
        let doc = EditorDocument(background: bg, fileURL: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let annData = try? Data(contentsOf: tmp.appendingPathComponent("annotations.json")),
           let anns = try? decoder.decode([Annotation].self, from: annData) {
            doc.annotations = anns
        }
        if let metaData = try? Data(contentsOf: tmp.appendingPathComponent("meta.json")),
           let meta = try? decoder.decode(Meta.self, from: metaData) {
            doc.stepCounter = meta.stepCounter
        }
        return doc
    }

    private static func thumbSize(for size: CGSize) -> CGSize {
        let maxDim: CGFloat = 320
        let ratio = min(1, maxDim / max(size.width, size.height))
        return CGSize(width: max(1, size.width * ratio), height: max(1, size.height * ratio))
    }
}

// MARK: - export

enum ExportFormat: String, CaseIterable {
    case png, jpeg, tiff, bmp, gif, pdf, fscx

    static func from(extension ext: String) -> ExportFormat? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "pdf": return .pdf
        case "fscx": return .fscx
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        default: return rawValue
        }
    }
}

enum Export {
    static func encode(_ image: CGImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: image.width, height: image.height)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg,
                                              properties: [.compressionFactor: Settings.shared.jpegQuality])
        }
    }

    /// Flattened export in any supported format.
    static func write(_ image: CGImage, to url: URL, format: ExportFormat) throws {
        if format == .pdf {
            try writePDF(image, to: url)
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: image.width, height: image.height)
        let type: NSBitmapImageRep.FileType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .tiff: type = .tiff
        case .bmp: type = .bmp
        case .gif: type = .gif
        case .pdf, .fscx: type = .png  // unreachable
        }
        var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if format == .jpeg { props[.compressionFactor] = Settings.shared.jpegQuality }
        guard let data = rep.representation(using: type, properties: props) else {
            throw FSCXError.zipFailed(Loc.t("编码 \(format.rawValue) 失败", "Failed to encode \(format.rawValue)"))
        }
        try data.write(to: url)
    }

    private static func writePDF(_ image: CGImage, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FSCXError.zipFailed(Loc.t("创建 PDF 失败", "Failed to create PDF"))
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
