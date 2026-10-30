import Foundation

/// Manages reading, writing, and synchronizing Adobe-standard XMP sidecar files (`<filename>.xmp`).
/// Provides seamless interoperability with Adobe Lightroom Classic, Adobe Camera Raw,
/// Capture One, Darktable, and Photo Mechanic.
public enum XmpSidecarManager {
    private static let fileManager = FileManager.default

    // Standard Adobe XMP XML namespaces
    public static let xmpMetaNS = "adobe:ns:meta/"
    public static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    public static let crsNS = "http://ns.adobe.com/camera-raw/1.0/"
    public static let photoshopNS = "http://ns.adobe.com/photoshop/1.0/"
    public static let tiffNS = "http://ns.adobe.com/tiff/1.0/"

    // MARK: - Sidecar Path Resolution

    /// Resolves the existing XMP sidecar file URL for an image, if one exists.
    /// Checks both the universal Adobe Lightroom standard (`<basename>.xmp`)
    /// and the suffix convention (`<filename>.xmp` / `<basename>.<ext>.xmp`).
    public static func existingSidecarURL(for imageURL: URL) -> URL? {
        // 1. Standard Adobe Lightroom / Capture One convention: photo.CR3 -> photo.xmp
        let standardURL = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        if fileManager.fileExists(atPath: standardURL.path) {
            return standardURL
        }

        // 2. Suffix convention: photo.CR3 -> photo.CR3.xmp (used by Darktable and some utilities)
        let altURL = imageURL.appendingPathExtension("xmp")
        if fileManager.fileExists(atPath: altURL.path) {
            return altURL
        }

        return nil
    }

    /// Resolves the target sidecar URL to write metadata to.
    /// If an existing sidecar file is found under either convention, that file is updated.
    /// Otherwise, defaults to the universal standard `<basename>.xmp`.
    public static func targetSidecarURL(for imageURL: URL) -> URL {
        if let existing = existingSidecarURL(for: imageURL) {
            return existing
        }
        return imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: - Reading Metadata

    /// Reads culling metadata (rating, pick, color, orientation) from a sidecar file if present.
    public static func read(from sidecarURL: URL) -> CullingMetadata {
        guard let data = try? Data(contentsOf: sidecarURL) else {
            return CullingMetadata()
        }
        return parse(data: data)
    }

    /// Reads culling metadata for an image file by automatically resolving its sidecar.
    public static func readMetadata(for imageURL: URL) -> CullingMetadata? {
        guard let sidecarURL = existingSidecarURL(for: imageURL) else {
            return nil
        }
        return read(from: sidecarURL)
    }

    /// Concurrently reads all existing sidecars for a list of items off the main thread.
    public static func loadAllSidecars(for items: [SlideItem]) async -> [String: CullingMetadata] {
        return await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: (String, CullingMetadata?).self) { group in
                for item in items {
                    group.addTask {
                        guard let sidecarURL = existingSidecarURL(for: item.url) else {
                            return (item.id, nil)
                        }
                        let meta = read(from: sidecarURL)
                        return (item.id, meta)
                    }
                }

                var dict: [String: CullingMetadata] = [:]
                for await (id, meta) in group {
                    if let meta = meta {
                        dict[id] = meta
                    }
                }
                return dict
            }
        }.value
    }

    /// Parses an XMP data payload into `CullingMetadata`.
    public static func parse(data: Data) -> CullingMetadata {
        guard let doc = try? XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodePreserveAll]) else {
            return CullingMetadata()
        }

        var rating = 0
        var pick: PickStatus = .unflagged
        var color: ColorLabel = .none
        var orientation: Int? = nil
        var profile: CameraProfile? = nil

        // Find all rdf:Description nodes
        let descriptions = (try? doc.nodes(forXPath: "//*[local-name()='Description']")) ?? []
        for node in descriptions {
            guard let elem = node as? XMLElement else { continue }

            // 1. Check Attributes
            for attr in elem.attributes ?? [] {
                let local = attr.localName ?? ""
                let val = attr.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                applyField(local: local, val: val, rating: &rating, pick: &pick, color: &color, orientation: &orientation, profile: &profile)
            }

            // 2. Check Child Elements (for tools that write elements instead of attributes)
            for child in elem.children ?? [] {
                let local = child.localName ?? ""
                let val = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                applyField(local: local, val: val, rating: &rating, pick: &pick, color: &color, orientation: &orientation, profile: &profile)
            }
        }

        return CullingMetadata(rating: rating, pick: pick, color: color, orientation: orientation, cameraProfile: profile)
    }

    private static func applyField(
        local: String,
        val: String,
        rating: inout Int,
        pick: inout PickStatus,
        color: inout ColorLabel,
        orientation: inout Int?,
        profile: inout CameraProfile?
    ) {
        if local == "Rating" {
            if let r = Int(val) {
                if r == -1 {
                    pick = .reject
                } else {
                    rating = max(0, min(5, r))
                }
            }
        } else if local == "PickStatus" {
            if val == "1" {
                pick = .pick
            } else if val == "-1" {
                pick = .reject
            } else if val == "0" {
                pick = .unflagged
            }
        } else if local == "Label" {
            if let c = colorLabel(from: val) {
                color = c
            }
        } else if local == "Urgency" {
            if color == .none, let c = colorLabel(from: val) {
                color = c
            }
        } else if local == "Orientation" {
            if let o = Int(val), (1...8).contains(o) {
                orientation = o
            }
        } else if local == "CameraProfile" {
            if let p = CameraProfile.from(xmpString: val) {
                profile = p
            }
        }
    }

    private static func colorLabel(from string: String) -> ColorLabel? {
        let lower = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "red", "6", "1":
            return .red
        case "yellow", "7", "2":
            return .yellow
        case "green", "8", "3":
            return .green
        case "blue", "9", "4":
            return .blue
        case "none", "0", "":
            return ColorLabel.none
        default:
            return nil
        }
    }

    // MARK: - Writing Metadata

    /// Writes or updates an XMP sidecar file for the given image URL asynchronously.
    /// Preserves existing metadata (Camera Raw edits, EXIF tags, keywords, etc.) if a sidecar exists.
    public static func save(metadata: CullingMetadata, for imageURL: URL) throws {
        let sidecarURL = targetSidecarURL(for: imageURL)
        let data = try serialize(metadata: metadata, targetURL: sidecarURL)
        try data.write(to: sidecarURL, options: .atomic)
    }

    /// Serializes `metadata` into an XMP XML data buffer.
    /// If a file already exists at `targetURL`, its existing tags are preserved.
    public static func serialize(metadata: CullingMetadata, targetURL: URL) throws -> Data {
        let targetLocalNames = ["Rating", "PickStatus", "Label", "Urgency", "Orientation", "CameraProfile"]

        if fileManager.fileExists(atPath: targetURL.path),
           let existingData = try? Data(contentsOf: targetURL),
           let doc = try? XMLDocument(data: existingData, options: [.nodePreserveWhitespace, .nodePreserveAll]) {

            let descriptions = (try? doc.nodes(forXPath: "//*[local-name()='Description']")) ?? []
            let desc: XMLElement

            if let first = descriptions.first as? XMLElement {
                desc = first
            } else {
                // Find or create rdf:RDF
                let rdfNodes = (try? doc.nodes(forXPath: "//*[local-name()='RDF']")) ?? []
                let rdf: XMLElement
                if let firstRdf = rdfNodes.first as? XMLElement {
                    rdf = firstRdf
                } else {
                    rdf = XMLElement(name: "rdf:RDF")
                    doc.rootElement()?.addChild(rdf)
                }
                desc = XMLElement(name: "rdf:Description")
                desc.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
                rdf.addChild(desc)
            }

            // Ensure standard namespaces exist
            ensureNamespaces(on: desc)

            // Remove existing rating / pick / color / orientation attributes
            for attr in (desc.attributes ?? []) where targetLocalNames.contains(attr.localName ?? "") {
                if let name = attr.name {
                    desc.removeAttribute(forName: name)
                }
            }

            // Remove existing child elements
            if let children = desc.children {
                for (idx, child) in children.enumerated().reversed() where targetLocalNames.contains(child.localName ?? "") {
                    desc.removeChild(at: idx)
                }
            }

            // Attach updated attributes
            applyMetadataAttributes(metadata, to: desc)

            return doc.xmlData(options: [.nodePrettyPrint])
        } else {
            // Create a brand-new standard Adobe XMP document
            return createNewXmpData(metadata: metadata)
        }
    }

    private static func ensureNamespaces(on elem: XMLElement) {
        let namespaces = [
            ("xmp", xmpNS),
            ("photoshop", photoshopNS),
            ("crs", crsNS),
            ("tiff", tiffNS)
        ]

        let existingPrefixes = Set((elem.namespaces ?? []).compactMap { $0.name })
        for (prefix, val) in namespaces {
            if !existingPrefixes.contains(prefix) {
                elem.addNamespace(XMLNode.namespace(withName: prefix, stringValue: val) as! XMLNode)
            }
        }
    }

    private static func applyMetadataAttributes(_ metadata: CullingMetadata, to desc: XMLElement) {
        // Rating
        if metadata.pick == .reject && metadata.rating == 0 {
            desc.addAttribute(XMLNode.attribute(withName: "xmp:Rating", stringValue: "-1") as! XMLNode)
        } else if metadata.rating > 0 {
            desc.addAttribute(XMLNode.attribute(withName: "xmp:Rating", stringValue: "\(metadata.rating)") as! XMLNode)
        }

        // Pick / Reject
        switch metadata.pick {
        case .pick:
            desc.addAttribute(XMLNode.attribute(withName: "crs:PickStatus", stringValue: "1") as! XMLNode)
        case .reject:
            desc.addAttribute(XMLNode.attribute(withName: "crs:PickStatus", stringValue: "-1") as! XMLNode)
        case .unflagged:
            break
        }

        // Color Labels
        if metadata.color != .none {
            desc.addAttribute(XMLNode.attribute(withName: "xmp:Label", stringValue: metadata.color.title) as! XMLNode)
            desc.addAttribute(XMLNode.attribute(withName: "photoshop:Urgency", stringValue: "\(metadata.color.rawValue)") as! XMLNode)
        }

        // Orientation
        if let o = metadata.orientation {
            desc.addAttribute(XMLNode.attribute(withName: "tiff:Orientation", stringValue: "\(o)") as! XMLNode)
        }

        // Camera Profile / Picture Control
        if let p = metadata.cameraProfile, p != .asShot {
            desc.addAttribute(XMLNode.attribute(withName: "crs:CameraProfile", stringValue: p.xmpCameraProfile) as! XMLNode)
        }
    }

    private static func createNewXmpData(metadata: CullingMetadata) -> Data {
        let root = XMLElement(name: "x:xmpmeta")
        root.addNamespace(XMLNode.namespace(withName: "x", stringValue: xmpMetaNS) as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "x:xmptk", stringValue: "Adobe XMP Core 7.0-c000") as! XMLNode)

        let rdf = XMLElement(name: "rdf:RDF")
        rdf.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: rdfNS) as! XMLNode)
        root.addChild(rdf)

        let desc = XMLElement(name: "rdf:Description")
        desc.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
        ensureNamespaces(on: desc)
        applyMetadataAttributes(metadata, to: desc)
        rdf.addChild(desc)

        let doc = XMLDocument(rootElement: root)
        let beginPI = XMLNode.processingInstruction(withName: "xpacket", stringValue: "begin=\"\u{feff}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"") as! XMLNode
        let endPI = XMLNode.processingInstruction(withName: "xpacket", stringValue: "end=\"w\"") as! XMLNode

        doc.insertChild(beginPI, at: 0)
        doc.addChild(endPI)

        return doc.xmlData(options: [.nodePrettyPrint])
    }
}
