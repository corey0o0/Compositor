import Foundation
import CoreGraphics

/// Layer-preserving PSD import via the vendored psd_sdk bridge (PSDLayerReader). Throws on anything
/// outside v1 scope (non-RGB, corrupt file, empty result) so the caller falls back to
/// ImageImporter's flattened decode.
actor PSDImporter {
    static let shared = PSDImporter()

    struct Result {
        let layers: [ImageLayer]
        let canvasSize: CGSize
    }

    // psd::blendMode::ToString() key -> Compositor's LayerBlendMode. Everything else (Pass Through,
    // Dissolve, Linear Burn, Darker/Lighter Color, Hard/Vivid/Linear/Pin Light, Hard Mix, Exclusion,
    // Subtract, Divide, Unknown) falls back to .normal, same as an unrecognized key.
    private static let blendModes: [String: LayerBlendMode] = [
        "NORMAL": .normal, "MULTIPLY": .multiply, "SCREEN": .screen, "OVERLAY": .overlay,
        "SOFT_LIGHT": .softLight, "DARKEN": .darken, "LIGHTEN": .lighten, "DIFFERENCE": .difference,
        "COLOR_DODGE": .colorDodge, "COLOR_BURN": .colorBurn, "HUE": .hue, "SATURATION": .saturation,
        "COLOR": .color, "LUMINOSITY": .luminosity,
    ]

    func decode(_ url: URL, remainingPixels: Int = 100_000_000) throws -> Result {
        try autoreleasepool {
            var canvasSize = CGSize.zero
            let records = try PSDDocument.layerRecords(withContentsOf: url, canvasSize: &canvasSize)
            guard canvasSize.width >= 1, canvasSize.height >= 1,
                  canvasSize.width <= 30_000, canvasSize.height <= 30_000 else {
                throw ImageImportError.unsupported
            }

            let usedPixels = records.reduce(0) { $0 + (($1.pixelImage.map { $0.width * $0.height }) ?? 0) }
            guard usedPixels <= remainingPixels else { throw ImageImportError.tooLarge }

            // Ids for every kept layer up front, matching the bridge's own two-pass approach: a
            // group's folder record appears *after* its children in file order, so a child's
            // parentID can reference a group not yet turned into an ImageLayer.
            var ids: [Int: UUID] = [:]
            for record in records { ids[record.layerID] = UUID() }

            var layers: [ImageLayer] = []
            layers.reserveCapacity(records.count)
            for record in records {
                let id = ids[record.layerID]!
                let parentID = record.parentLayerID >= 0 ? ids[record.parentLayerID] : nil
                let blendMode = Self.blendModes[record.blendMode] ?? .normal

                if record.isGroup {
                    // Photoshop group bounds are typically degenerate; folders just cover the canvas.
                    let transform = LayerTransform(origin: .zero, size: canvasSize)
                    layers.append(ImageLayer(id: id, asset: nil, name: record.name, isVisible: record.isVisible,
                        transform: transform, parentID: parentID, isGroup: true, opacity: record.opacity, blendMode: blendMode))
                    continue
                }

                guard let pixelImage = record.pixelImage else { continue } // No channel data: nothing to place.
                let transform = LayerTransform(origin: record.bounds.origin, size: record.bounds.size)
                guard transform.isValid else { continue }
                let thumbnail = try PixelAdjust.thumbnail(of: pixelImage)
                let asset = ImportedImage(image: pixelImage, thumbnail: thumbnail, name: record.name)

                var mask: LayerMask?
                if let maskImage = record.maskImage {
                    let maskAsset = try LayerMask.asset(from: maskImage)
                    let coversLayer = record.maskBounds.origin == record.bounds.origin && record.maskBounds.size == record.bounds.size
                    let placement = coversLayer ? nil : LayerTransform(origin: record.maskBounds.origin, size: record.maskBounds.size)
                    mask = LayerMask(asset: maskAsset, placement: placement)
                }

                layers.append(ImageLayer(id: id, asset: asset, name: record.name, isVisible: record.isVisible,
                    transform: transform, parentID: parentID, isGroup: false, opacity: record.opacity,
                    blendMode: blendMode, mask: mask))
            }

            guard !layers.isEmpty else { throw ImageImportError.unreadable }
            return Result(layers: layers, canvasSize: canvasSize)
        }
    }
}
