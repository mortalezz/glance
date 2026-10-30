import Foundation
import CoreGraphics
import Accelerate
import os

@main
struct TestRunner {
    static func assertTrue(_ condition: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
        if !condition {
            print("❌ ASSERTION FAILED: \(msg) [\(file):\(line)]")
            exit(1)
        }
    }

    static func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
        if a != b {
            print("❌ ASSERTION FAILED: expected '\(b)', got '\(a)'. \(msg) [\(file):\(line)]")
            exit(1)
        }
    }

    static func makeTestCGImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
            bytes[i + 3] = a
        }
        let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    static func main() async throws {
        print("🧪 Starting Glance Engineering Test Suite...")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GlanceTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // TEST 1: Parse standard Adobe attribute format
        do {
            print("▶ Testing standard Adobe attribute format parsing...")
            let xmp = """
            <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                xmlns:crs="http://ns.adobe.com/camera-raw/1.0/"
                xmp:Rating="4"
                xmp:Label="Red"
                crs:PickStatus="1">
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """

            let meta = XmpSidecarManager.parse(data: xmp.data(using: .utf8)!)
            assertEqual(meta.rating, 4, "Rating should be 4")
            assertEqual(meta.pick, .pick, "Pick should be .pick")
            assertEqual(meta.color, .red, "Color should be .red")
            print("  ✅ Passed")
        }

        // TEST 2: Parse element-based format (Capture One / Darktable style)
        do {
            print("▶ Testing element-based format parsing...")
            let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:cr="http://ns.adobe.com/camera-raw/1.0/">
               <xmp:Rating>3</xmp:Rating>
               <xmp:Label>Green</xmp:Label>
               <cr:PickStatus>-1</cr:PickStatus>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """

            let meta = XmpSidecarManager.parse(data: xmp.data(using: .utf8)!)
            assertEqual(meta.rating, 3, "Rating should be 3")
            assertEqual(meta.pick, .reject, "Pick should be .reject")
            assertEqual(meta.color, .green, "Color should be .green")
            print("  ✅ Passed")
        }

        // TEST 3: Darktable rating -1 reject format
        do {
            print("▶ Testing Darktable Rating=-1 reject convention...")
            let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="-1">
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """

            let meta = XmpSidecarManager.parse(data: xmp.data(using: .utf8)!)
            assertEqual(meta.rating, 0, "Rating should be clamped to 0")
            assertEqual(meta.pick, .reject, "Pick should be .reject")
            print("  ✅ Passed")
        }

        // TEST 4: Color label parsing across strings and numeric IPTC urgency
        do {
            print("▶ Testing Color Labels and IPTC urgency codes...")
            let colors: [(String, ColorLabel)] = [
                ("Yellow", .yellow),
                ("yellow", .yellow),
                ("Blue", .blue),
                ("Green", .green),
                ("Red", .red),
                ("None", .none),
                ("6", .red),
                ("7", .yellow),
                ("8", .green),
                ("9", .blue)
            ]

            for (str, expected) in colors {
                let xmp = """
                <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                  <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Label="\(str)" />
                </rdf:RDF>
                """
                let meta = XmpSidecarManager.parse(data: xmp.data(using: .utf8)!)
                assertEqual(meta.color, expected, "Failed for color string '\(str)'")
            }
            print("  ✅ Passed")
        }

        // TEST 5: Create brand-new XMP file from scratch
        do {
            print("▶ Testing brand-new XMP file creation...")
            let imageURL = tempDir.appendingPathComponent("_DSC1000.ARW")
            try Data().write(to: imageURL)

            let initialMeta = CullingMetadata(rating: 5, pick: .pick, color: .yellow)
            try XmpSidecarManager.save(metadata: initialMeta, for: imageURL)

            let sidecarURL = tempDir.appendingPathComponent("_DSC1000.xmp")
            assertTrue(FileManager.default.fileExists(atPath: sidecarURL.path), "Sidecar file should exist")

            let readBack = XmpSidecarManager.read(from: sidecarURL)
            assertEqual(readBack.rating, 5, "Rating should be 5")
            assertEqual(readBack.pick, .pick, "Pick should be .pick")
            assertEqual(readBack.color, .yellow, "Color should be .yellow")

            let content = try String(contentsOf: sidecarURL, encoding: .utf8)
            assertTrue(content.contains("<?xpacket begin="), "Must contain xpacket header")
            assertTrue(content.contains("<?xpacket end="), "Must contain xpacket footer")
            assertTrue(content.contains("xmp:Rating=\"5\""), "Must contain rating 5")
            assertTrue(content.contains("crs:PickStatus=\"1\""), "Must contain crs:PickStatus 1")
            assertTrue(content.contains("xmp:Label=\"Yellow\""), "Must contain xmp:Label Yellow")
            print("  ✅ Passed")
        }

        // TEST 6: Update existing XMP file while preserving non-culling develop & EXIF settings
        do {
            print("▶ Testing metadata preservation on existing XMP files...")
            let imageURL = tempDir.appendingPathComponent("IMG_0042.CR3")
            let sidecarURL = tempDir.appendingPathComponent("IMG_0042.xmp")

            let existingContent = """
            <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:crs="http://ns.adobe.com/camera-raw/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                crs:Exposure2012="+0.75"
                crs:Temperature="5800"
                crs:Tint="+10"
                photoshop:Credit="Test Photographer"
                xmp:Rating="1">
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
            try existingContent.write(to: sidecarURL, atomically: true, encoding: .utf8)

            // Update metadata
            let updatedMeta = CullingMetadata(rating: 4, pick: .pick, color: .blue)
            try XmpSidecarManager.save(metadata: updatedMeta, for: imageURL)

            let updatedContent = try String(contentsOf: sidecarURL, encoding: .utf8)
            assertTrue(updatedContent.contains("xmp:Rating=\"4\""), "Rating should be 4")
            assertTrue(updatedContent.contains("crs:PickStatus=\"1\""), "crs:PickStatus should be 1")
            assertTrue(updatedContent.contains("xmp:Label=\"Blue\""), "Color should be Blue")

            // Verify non-destructive preservation
            assertTrue(updatedContent.contains("crs:Exposure2012=\"+0.75\""), "Exposure must be preserved")
            assertTrue(updatedContent.contains("crs:Temperature=\"5800\""), "Temperature must be preserved")
            assertTrue(updatedContent.contains("crs:Tint=\"+10\""), "Tint must be preserved")
            assertTrue(updatedContent.contains("photoshop:Credit=\"Test Photographer\""), "Credit must be preserved")
            print("  ✅ Passed")
        }

        // TEST 7: Preserve Darktable suffix convention (photo.NEF.xmp)
        do {
            print("▶ Testing preservation of suffix naming convention (photo.NEF.xmp)...")
            let imageURL = tempDir.appendingPathComponent("shot.NEF")
            let altSidecar = tempDir.appendingPathComponent("shot.NEF.xmp")

            let initialContent = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2"/>
             </rdf:RDF>
            </x:xmpmeta>
            """
            try initialContent.write(to: altSidecar, atomically: true, encoding: .utf8)

            let target = XmpSidecarManager.targetSidecarURL(for: imageURL)
            assertEqual(target.path, altSidecar.path, "Should preserve existing suffix sidecar path")

            try XmpSidecarManager.save(metadata: CullingMetadata(rating: 5), for: imageURL)

            let readBack = XmpSidecarManager.read(from: altSidecar)
            assertEqual(readBack.rating, 5, "Rating should be updated in shot.NEF.xmp")

            let standardSidecar = tempDir.appendingPathComponent("shot.xmp")
            assertTrue(!FileManager.default.fileExists(atPath: standardSidecar.path), "Should not create duplicate shot.xmp")
            print("  ✅ Passed")
        }

        // TEST 8: Concurrent batch sidecar loading
        do {
            print("▶ Testing concurrent batch loading of directory sidecars...")
            var items: [SlideItem] = []
            for i in 1...20 {
                let imgURL = tempDir.appendingPathComponent("batch_\(i).JPG")
                try Data().write(to: imgURL)

                if i % 2 == 0 {
                    let meta = CullingMetadata(rating: (i % 5) + 1, pick: (i % 4 == 0) ? .pick : .unflagged)
                    try XmpSidecarManager.save(metadata: meta, for: imgURL)
                }
                items.append(SlideItem(url: imgURL, fileSize: 1024))
            }

            let loaded = await XmpSidecarManager.loadAllSidecars(for: items)
            assertEqual(loaded.count, 10, "Should load exactly 10 sidecars")

            for i in stride(from: 2, through: 20, by: 2) {
                let id = tempDir.appendingPathComponent("batch_\(i).JPG").path
                let meta = loaded[id]
                assertTrue(meta != nil, "Item \(i) should have metadata")
                assertEqual(meta?.rating, (i % 5) + 1, "Item \(i) should have matching rating")
            }
            print("  ✅ Passed")
        }

        // TEST 9: RAW + JPEG Sibling Stacking in DirectoryScanner
        do {
            print("▶ Testing RAW + JPEG Sibling Stacking in DirectoryScanner...")
            let stackDir = tempDir.appendingPathComponent("StackTest_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stackDir, withIntermediateDirectories: true)

            // Shot 1: ARW + JPG pair
            let raw1 = stackDir.appendingPathComponent("_DSC0001.ARW")
            let jpg1 = stackDir.appendingPathComponent("_DSC0001.JPG")
            try Data(repeating: 1, count: 24_000_000).write(to: raw1)
            try Data(repeating: 2, count: 4_000_000).write(to: jpg1)

            // Shot 2: RAW only (CR3)
            let raw2 = stackDir.appendingPathComponent("_DSC0002.CR3")
            try Data(repeating: 3, count: 30_000_000).write(to: raw2)

            // Shot 3: JPEG only
            let jpg3 = stackDir.appendingPathComponent("_DSC0003.JPG")
            try Data(repeating: 4, count: 5_000_000).write(to: jpg3)

            let scanner = DirectoryScanner()
            let scanResult = try await scanner.scan(targetURL: stackDir)

            // Should collapse 4 files into 3 SlideItems!
            assertEqual(scanResult.items.count, 3, "4 physical files must produce exactly 3 slide items")

            // Verify Shot 1 stack properties
            let stackItem = scanResult.items[0]
            assertTrue(stackItem.isStacked, "Shot 1 must be stacked")
            assertEqual(stackItem.rawURL?.lastPathComponent, "_DSC0001.ARW", "rawURL should be ARW")
            assertEqual(stackItem.companionURL?.lastPathComponent, "_DSC0001.JPG", "companionURL should be JPG")
            assertEqual(stackItem.url.lastPathComponent, "_DSC0001.JPG", "Primary url should be the fast companion JPG")
            assertEqual(stackItem.displayName, "_DSC0001.ARW + JPG", "Display title should show stack")
            assertEqual(stackItem.allURLs.count, 2, "allURLs must contain both RAW and JPG")
            assertEqual(stackItem.totalStackSize, 28_000_000, "totalStackSize must be sum of both")

            // Verify Shot 2 (RAW only)
            let rawOnlyItem = scanResult.items[1]
            assertTrue(!rawOnlyItem.isStacked, "Shot 2 is not stacked")
            assertEqual(rawOnlyItem.rawURL?.lastPathComponent, "_DSC0002.CR3", "rawURL should be CR3")
            assertEqual(rawOnlyItem.companionURL, nil, "companionURL should be nil")
            assertEqual(rawOnlyItem.url.lastPathComponent, "_DSC0002.CR3", "Primary url should be CR3")

            // Verify Shot 3 (JPEG only)
            let jpgOnlyItem = scanResult.items[2]
            assertTrue(!jpgOnlyItem.isStacked, "Shot 3 is not stacked")
            assertEqual(jpgOnlyItem.rawURL, nil, "rawURL should be nil")
            assertEqual(jpgOnlyItem.url.lastPathComponent, "_DSC0003.JPG", "Primary url should be JPG")

            print("  ✅ Passed")
        }

        // TEST 10: Initial Index Resolution when opening RAW or JPEG companion directly
        do {
            print("▶ Testing Initial Index Resolution on paired shots...")
            let stackDir = tempDir.appendingPathComponent("IndexTest_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stackDir, withIntermediateDirectories: true)

            let raw1 = stackDir.appendingPathComponent("_DSC0001.ARW")
            let jpg1 = stackDir.appendingPathComponent("_DSC0001.JPG")
            let raw2 = stackDir.appendingPathComponent("_DSC0002.ARW")
            let jpg2 = stackDir.appendingPathComponent("_DSC0002.JPG")
            try Data().write(to: raw1)
            try Data().write(to: jpg1)
            try Data().write(to: raw2)
            try Data().write(to: jpg2)

            let scanner = DirectoryScanner()

            // Open via _DSC0002.JPG
            let resultFromJPG = try await scanner.scan(targetURL: jpg2)
            assertEqual(resultFromJPG.initialIndex, 1, "Opening _DSC0002.JPG must navigate to stack index 1")

            // Open via _DSC0002.ARW
            let resultFromRAW = try await scanner.scan(targetURL: raw2)
            assertEqual(resultFromRAW.initialIndex, 1, "Opening _DSC0002.ARW must navigate to stack index 1")

            print("  ✅ Passed")
        }

        // TEST 11: Phase 3 Histogram Engine (RGB + Rec. 709 Luminance)
        do {
            print("▶ Testing Phase 3 HistogramEngine computation...")
            // Pure white 4x4 image
            let whiteImg = makeTestCGImage(width: 4, height: 4, r: 255, g: 255, b: 255)
            let whiteHist = HistogramEngine.compute(for: whiteImg)
            assertEqual(whiteHist.red[255], 16, "White: all 16 pixels must be in red bin 255")
            assertEqual(whiteHist.green[255], 16, "White: all 16 pixels must be in green bin 255")
            assertEqual(whiteHist.blue[255], 16, "White: all 16 pixels must be in blue bin 255")
            assertEqual(whiteHist.luminance[255], 16, "White: all 16 pixels must be in luminance bin 255")
            assertEqual(whiteHist.red[0], 0, "White: bin 0 should be 0")

            // Pure black 4x4 image
            let blackImg = makeTestCGImage(width: 4, height: 4, r: 0, g: 0, b: 0)
            let blackHist = HistogramEngine.compute(for: blackImg)
            assertEqual(blackHist.red[0], 16, "Black: all 16 pixels must be in red bin 0")
            assertEqual(blackHist.luminance[0], 16, "Black: all 16 pixels must be in luminance bin 0")

            // Pure Green image (Rec. 709 Luminance weight: Y = 255 * 0.7152 ≈ 182)
            let greenImg = makeTestCGImage(width: 4, height: 4, r: 0, g: 255, b: 0)
            let greenHist = HistogramEngine.compute(for: greenImg)
            assertEqual(greenHist.green[255], 16, "Green channel bin 255")
            assertEqual(greenHist.red[0], 16, "Red channel bin 0")
            assertEqual(greenHist.luminance[182], 16, "Green luminance should be at bin 182")

            print("  ✅ Passed")
        }

        // TEST 12: Phase 3 Exposure Clipping Mask Engine ("Blinkies")
        do {
            print("▶ Testing Phase 3 ClippingEngine exposure warning detection...")
            // Blown highlights: pure white triggers highlight clipping
            let blownImg = makeTestCGImage(width: 4, height: 4, r: 255, g: 255, b: 255)
            let blownMask = ClippingEngine.generateClippingMask(for: blownImg)
            assertTrue(blownMask != nil, "Blown highlights must generate clipping mask")

            // Crushed shadows: pure black triggers shadow clipping
            let crushedImg = makeTestCGImage(width: 4, height: 4, r: 0, g: 0, b: 0)
            let crushedMask = ClippingEngine.generateClippingMask(for: crushedImg)
            assertTrue(crushedMask != nil, "Crushed shadows must generate clipping mask")

            // Well-exposed midtones (128, 128, 128): no clipping
            let midtoneImg = makeTestCGImage(width: 4, height: 4, r: 128, g: 128, b: 128)
            let midtoneMask = ClippingEngine.generateClippingMask(for: midtoneImg)
            assertTrue(midtoneMask == nil, "Well-exposed image must not produce clipping mask")

            print("  ✅ Passed")
        }

        // TEST 13: EXIF Metadata Parsing & Formatting
        do {
            print("▶ Testing EXIF Metadata extraction and formatting...")
            let mockProps: [CFString: Any] = [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Sony",
                    kCGImagePropertyTIFFModel: "ILCE-7RM5"
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifExposureTime: 0.002, // 1/500s
                    kCGImagePropertyExifFNumber: 2.8,       // f/2.8
                    kCGImagePropertyExifISOSpeedRatings: [400],
                    kCGImagePropertyExifFocalLength: 85.0,  // 85mm
                    kCGImagePropertyExifLensModel: "FE 85mm F1.4 GM",
                    kCGImagePropertyExifExposureBiasValue: 0.3,
                    kCGImagePropertyExifDateTimeOriginal: "2026:10:27 15:42:00"
                ]
            ]

            let meta = ExifMetadata(from: mockProps)
            assertEqual(meta.cameraMake, "Sony", "Camera make")
            assertEqual(meta.cameraModel, "ILCE-7RM5", "Camera model")
            assertEqual(meta.formattedShutter, "1/500s", "Shutter speed format")
            assertEqual(meta.formattedAperture, "ƒ/2.8", "Aperture format")
            assertEqual(meta.formattedIso, "ISO 400", "ISO format")
            assertEqual(meta.formattedFocal, "85mm", "Focal length format")
            assertEqual(meta.formattedBias, "+0.3 EV", "Exposure bias format")
            assertEqual(meta.exposureSummary, "1/500s · ƒ/2.8 · ISO 400 · 85mm · +0.3 EV", "Exposure summary string")
            assertEqual(meta.cameraAndLensSummary, "Sony ILCE-7RM5 · FE 85mm F1.4 GM", "Camera and lens line")
            print("  ✅ Passed")
        }

        // TEST 14: Phase 4 ExportManager Batch Copy
        do {
            print("▶ Testing Phase 4 ExportManager batch copy with stacked shots and XMP sidecars...")
            let exportSrcDir = tempDir.appendingPathComponent("ExportSrc_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: exportSrcDir, withIntermediateDirectories: true)

            // Shot 1: Stacked ARW + JPG + XMP
            let raw1 = exportSrcDir.appendingPathComponent("_DSC1000.ARW")
            let jpg1 = exportSrcDir.appendingPathComponent("_DSC1000.JPG")
            try Data("RAW-DATA".utf8).write(to: raw1)
            try Data("JPG-DATA".utf8).write(to: jpg1)
            try XmpSidecarManager.save(metadata: CullingMetadata(rating: 5, pick: .pick), for: jpg1)

            let stackItem = SlideItem(
                url: jpg1,
                rawURL: raw1,
                companionURL: jpg1,
                allURLs: [raw1, jpg1],
                fileSize: 8,
                totalStackSize: 16
            )

            // Shot 2: Single JPG
            let jpg2 = exportSrcDir.appendingPathComponent("_DSC1001.JPG")
            try Data("JPG2-DATA".utf8).write(to: jpg2)
            let singleItem = SlideItem(url: jpg2, fileSize: 9)

            let picksDir = exportSrcDir.appendingPathComponent("Picks")

            let counter = OSAllocatedUnfairLock(initialState: 0)
            let summary = try await ExportManager.shared.export(
                items: [stackItem, singleItem],
                destinationDirectory: picksDir
            ) { _ in
                counter.withLock { $0 += 1 }
            }

            assertEqual(summary.exportedCount, 2, "Both items should export successfully")
            assertEqual(summary.totalFilesWritten, 4, "Must write RAW, JPG, XMP for shot 1 and JPG for shot 2")
            assertTrue(FileManager.default.fileExists(atPath: picksDir.appendingPathComponent("_DSC1000.ARW").path), "Exported RAW must exist")
            assertTrue(FileManager.default.fileExists(atPath: picksDir.appendingPathComponent("_DSC1000.JPG").path), "Exported companion JPG must exist")
            assertTrue(FileManager.default.fileExists(atPath: picksDir.appendingPathComponent("_DSC1000.xmp").path), "Exported XMP sidecar must exist")
            assertTrue(FileManager.default.fileExists(atPath: picksDir.appendingPathComponent("_DSC1001.JPG").path), "Exported single JPG must exist")
            assertEqual(counter.withLock { $0 }, 2, "Progress callback reported for both items")
            print("  ✅ Passed")
        }

        // TEST 15: Phase 4 LosslessRotationEngine (EXIF Orientation & XMP)
        do {
            print("▶ Testing Phase 4 LosslessRotationEngine orientation transitions...")
            // Test 90° Clockwise cycle: 1 -> 6 -> 3 -> 8 -> 1
            assertEqual(LosslessRotationEngine.nextOrientation(current: 1, direction: .clockwise), 6, "1 -> CW -> 6")
            assertEqual(LosslessRotationEngine.nextOrientation(current: 6, direction: .clockwise), 3, "6 -> CW -> 3")
            assertEqual(LosslessRotationEngine.nextOrientation(current: 3, direction: .clockwise), 8, "3 -> CW -> 8")
            assertEqual(LosslessRotationEngine.nextOrientation(current: 8, direction: .clockwise), 1, "8 -> CW -> 1")

            // Test 90° Counter-Clockwise cycle: 1 -> 8 -> 3 -> 6 -> 1
            assertEqual(LosslessRotationEngine.nextOrientation(current: 1, direction: .counterClockwise), 8, "1 -> CCW -> 8")
            assertEqual(LosslessRotationEngine.nextOrientation(current: 8, direction: .counterClockwise), 3, "8 -> CCW -> 3")
            assertEqual(LosslessRotationEngine.nextOrientation(current: 3, direction: .counterClockwise), 6, "3 -> CCW -> 6")
            assertEqual(LosslessRotationEngine.nextOrientation(current: 6, direction: .counterClockwise), 1, "6 -> CCW -> 1")

            // Test In-place lossless rotation of JPEG file
            let rotDir = tempDir.appendingPathComponent("RotTest_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: rotDir, withIntermediateDirectories: true)
            let rotJPG = rotDir.appendingPathComponent("photo.jpg")

            let cgImg = makeTestCGImage(width: 20, height: 10, r: 200, g: 100, b: 50)
            let dest = CGImageDestinationCreateWithURL(rotJPG as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cgImg, [kCGImagePropertyOrientation: 1] as CFDictionary)
            CGImageDestinationFinalize(dest)

            assertEqual(LosslessRotationEngine.currentOrientation(for: rotJPG), 1, "Initial orientation must be 1")

            let itemToRotate = SlideItem(url: rotJPG, fileSize: 100)
            let newOri = try LosslessRotationEngine.rotate(item: itemToRotate, direction: .clockwise)
            assertEqual(newOri, 6, "New orientation returned should be 6")
            assertEqual(LosslessRotationEngine.currentOrientation(for: rotJPG), 6, "Physical file EXIF orientation must now be 6")

            // Rotate again clockwise -> 3
            let nextOri = try LosslessRotationEngine.rotate(item: itemToRotate, direction: .clockwise)
            assertEqual(nextOri, 3, "Second rotation should be 3")
            assertEqual(LosslessRotationEngine.currentOrientation(for: rotJPG), 3, "Physical file EXIF orientation must now be 3")

            // Verify XMP sidecar orientation synchronization
            let xmpFile = rotDir.appendingPathComponent("photo.xmp")
            let readXmp = XmpSidecarManager.read(from: xmpFile)
            assertEqual(readXmp.orientation, 3, "XMP sidecar tiff:Orientation must be synchronized to 3")

            print("  ✅ Passed")
        }

        // TEST 16: FaceDetectionEngine & Eye Focus Jump
        do {
            print("▶ Testing FaceDetectionEngine Apple Vision integration and caching...")
            let engine = FaceDetectionEngine.shared
            engine.clearCache()

            // 1. Test blank synthetic image (safely returns 0 faces)
            let blankImg = makeTestCGImage(width: 100, height: 100, r: 120, g: 120, b: 120)
            let emptyFaces = await engine.detectFaces(in: blankImg, cacheKey: "blank_test")
            assertEqual(emptyFaces.count, 0, "Blank synthetic image has 0 faces")

            // 2. Test cache hit
            let cached = engine.cachedFaces(for: "blank_test")
            assertTrue(cached != nil, "Face results should be cached by key")
            assertEqual(cached?.count, 0, "Cached count matches")

            // 3. Test coordinate math for DetectedFace
            let mockBox = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.4)
            let mockFace = DetectedFace(
                boundingBox: mockBox,
                eyeCenter: CGPoint(x: 0.5, y: 0.65),
                leftEye: CGPoint(x: 0.4, y: 0.65),
                rightEye: CGPoint(x: 0.6, y: 0.65),
                confidence: 0.95
            )
            assertEqual(mockFace.eyeCenter.x, 0.5, "Eye center X coordinate")
            assertEqual(mockFace.eyeCenter.y, 0.65, "Eye center Y coordinate")

            print("  ✅ Passed")
        }

        // TEST 17: Multi-Level Undo & Redo (CullingUndoManager & Trash Restoration)
        do {
            print("▶ Testing CullingUndoManager action recording, undo/redo stacks, and trash restoration...")
            let undoMgr = CullingUndoManager()
            undoMgr.clear()
            assertTrue(!undoMgr.canUndo, "Undo stack should initially be empty")
            assertTrue(!undoMgr.canRedo, "Redo stack should initially be empty")

            // 1. Record rating action
            undoMgr.record(.rating(itemID: "item1", rawIndex: 0, previous: 0, new: 5))
            assertTrue(undoMgr.canUndo, "Should be able to undo after recording")
            assertTrue(!undoMgr.canRedo, "Redo stack cleared on new action")

            // 2. Undo rating
            guard let poppedAction = undoMgr.popUndo() else {
                fatalError("Expected action to pop")
            }
            if case .rating(let id, _, let prev, let new) = poppedAction {
                assertEqual(id, "item1", "Item ID matches")
                assertEqual(prev, 0, "Previous rating restored to 0")
                assertEqual(new, 5, "New rating was 5")
            } else {
                fatalError("Unexpected action type")
            }
            assertTrue(undoMgr.canRedo, "Should be able to redo after undo")

            // 3. Redo rating
            guard let redoAction = undoMgr.popRedo() else {
                fatalError("Expected redo action")
            }
            if case .rating(let id, _, _, let new) = redoAction {
                assertEqual(id, "item1", "Item ID matches")
                assertEqual(new, 5, "Redone rating is 5")
            } else {
                fatalError("Unexpected redo action type")
            }

            // 4. Test physical trash and restoration via TrashManager
            let trashTestDir = tempDir.appendingPathComponent("TrashTest_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: trashTestDir, withIntermediateDirectories: true)
            let testFile = trashTestDir.appendingPathComponent("undo_test.jpg")
            try Data("PHOTO-BYTES".utf8).write(to: testFile)

            let trashedURL = try await TrashManager.moveToTrash(url: testFile)
            assertTrue(!FileManager.default.fileExists(atPath: testFile.path), "Original file moved to trash")

            let record = TrashedFileRecord(originalURL: testFile, trashedURL: trashedURL)
            try await TrashManager.restore(record: record)
            assertTrue(FileManager.default.fileExists(atPath: testFile.path), "File restored to original path")
            let restoredData = try Data(contentsOf: testFile)
            assertEqual(String(data: restoredData, encoding: .utf8), "PHOTO-BYTES", "Restored content intact")

            print("  ✅ Passed")
        }

        print("\n🎉 ALL GLANCE ENGINEERING TESTS PASSED SUCCESSFULLY!")
    }
}
