// Objective-C bridge over the vendored psd_sdk (Compositor/ThirdParty/psd_sdk). Keeps every C++ type
// on the .mm side; Swift only ever sees PSDDocument/PSDLayerRecord.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const PSDReaderErrorDomain;

typedef NS_ERROR_ENUM(PSDReaderErrorDomain, PSDReaderErrorCode) {
    PSDReaderErrorUnsupported = 1, // Not RGB, or otherwise outside v1 scope.
    PSDReaderErrorParseFailed = 2,
};

/// One layer or group, in the same bottom-to-top order psd_sdk stores them in (which matches
/// CanvasDocument.layers). Section-divider bounding layers are never emitted.
@interface PSDLayerRecord : NSObject

- (instancetype)initWithName:(NSString *)name
                      layerID:(NSInteger)layerID
                parentLayerID:(NSInteger)parentLayerID
                       bounds:(CGRect)bounds
                      isGroup:(BOOL)isGroup
                      opacity:(double)opacity
                    isVisible:(BOOL)isVisible
                    blendMode:(NSString *)blendMode
                   pixelImage:(nullable CGImageRef)pixelImage
                    maskImage:(nullable CGImageRef)maskImage
                   maskBounds:(CGRect)maskBounds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, assign) NSInteger layerID;
/// -1 for a top-level layer/group.
@property (nonatomic, readonly, assign) NSInteger parentLayerID;
/// Layer's own bounds in document pixel space (origin top-left, y down).
@property (nonatomic, readonly, assign) CGRect bounds;
@property (nonatomic, readonly, assign) BOOL isGroup;
/// 0-1.
@property (nonatomic, readonly, assign) double opacity;
@property (nonatomic, readonly, assign) BOOL isVisible;
/// psd::blendMode::ToString() value, e.g. "NORMAL", "MULTIPLY".
@property (nonatomic, readonly, copy) NSString *blendMode;
/// Premultiplied RGBA8, sized to `bounds`. Nil for groups and layers with no channel data.
@property (nonatomic, readonly, nullable) CGImageRef pixelImage;
/// 8-bit grayscale, no alpha, sized to `maskBounds`. Nil when the layer has no user mask.
@property (nonatomic, readonly, nullable) CGImageRef maskImage;
@property (nonatomic, readonly, assign) CGRect maskBounds;

@end

@interface PSDDocument : NSObject

/// Parses the whole PSD in one shot. Returns nil (with *error set) for anything outside v1 scope
/// (non-RGB color mode, PSB/64-bit oddities psd_sdk itself rejects, corrupt files) so the caller
/// can fall back to a flattened import. `canvasSize` (when non-null) receives the document's own
/// pixel dimensions, which layer bounds don't necessarily cover (e.g. an empty canvas, or every
/// layer cropped smaller than the canvas).
+ (nullable NSArray<PSDLayerRecord *> *)layerRecordsWithContentsOfURL:(NSURL *)url
                                                             canvasSize:(nullable CGSize *)canvasSize
                                                                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
