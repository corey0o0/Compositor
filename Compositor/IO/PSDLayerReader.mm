// Objective-C++ bridge over the vendored psd_sdk. See PSDLayerReader.h for the public surface;
// every psd:: type stays local to this translation unit.
#import "PSDLayerReader.h"

#include "../ThirdParty/psd_sdk/PsdPch.h"
#include "../ThirdParty/psd_sdk/PsdMallocAllocator.h"
#include "../ThirdParty/psd_sdk/PsdMemoryFile.h"
#include "../ThirdParty/psd_sdk/PsdParseDocument.h"
#include "../ThirdParty/psd_sdk/PsdParseLayerMaskSection.h"
#include "../ThirdParty/psd_sdk/PsdDocument.h"
#include "../ThirdParty/psd_sdk/PsdLayerMaskSection.h"
#include "../ThirdParty/psd_sdk/PsdLayer.h"
#include "../ThirdParty/psd_sdk/PsdLayerMask.h"
#include "../ThirdParty/psd_sdk/PsdChannel.h"
#include "../ThirdParty/psd_sdk/PsdChannelType.h"
#include "../ThirdParty/psd_sdk/PsdLayerType.h"
#include "../ThirdParty/psd_sdk/PsdColorMode.h"
#include "../ThirdParty/psd_sdk/PsdBlendMode.h"

#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <vector>

NSErrorDomain const PSDReaderErrorDomain = @"PSDReaderErrorDomain";

#pragma mark - PSDLayerRecord

@implementation PSDLayerRecord

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
                   maskBounds:(CGRect)maskBounds
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _layerID = layerID;
        _parentLayerID = parentLayerID;
        _bounds = bounds;
        _isGroup = isGroup;
        _opacity = opacity;
        _isVisible = isVisible;
        _blendMode = [blendMode copy];
        _pixelImage = pixelImage ? CGImageRetain(pixelImage) : NULL;
        _maskImage = maskImage ? CGImageRetain(maskImage) : NULL;
        _maskBounds = maskBounds;
    }
    return self;
}

- (void)dealloc
{
    if (_pixelImage) {
        CGImageRelease(_pixelImage);
    }
    if (_maskImage) {
        CGImageRelease(_maskImage);
    }
}

@end

#pragma mark - Internal helpers

namespace {

NSError *MakeError(PSDReaderErrorCode code)
{
    return [NSError errorWithDomain:PSDReaderErrorDomain code:code userInfo:nil];
}

// Raw channel data is a flat array of samples, one per pixel; interpretation depends on bitsPerChannel.
// 16-bit samples are stored in Photoshop's documented 0...32768 range, not the naively-expected 0...65535
// (see PsdParseImageDataSection.cpp), so the divisor below is intentional.
float SampleU8(const uint8_t *base, size_t index) { return base[index] / 255.0f; }
float SampleU16(const uint8_t *base, size_t index)
{
    return std::min(reinterpret_cast<const uint16_t *>(base)[index] / 32768.0f, 1.0f);
}
float SampleF32(const uint8_t *base, size_t index)
{
    return std::clamp(reinterpret_cast<const float *>(base)[index], 0.0f, 1.0f);
}

using SampleFn = float (*)(const uint8_t *, size_t);

SampleFn SampleFnForBits(unsigned int bitsPerChannel)
{
    switch (bitsPerChannel) {
        case 16: return &SampleU16;
        case 32: return &SampleF32;
        default: return &SampleU8;
    }
}

const psd::Channel *FindChannel(const psd::Layer *layer, int16_t type)
{
    for (unsigned int i = 0; i < layer->channelCount; ++i) {
        if (layer->channels[i].type == type) {
            return &layer->channels[i];
        }
    }
    return nullptr;
}

// Wraps `data` in a CFData-owned CGDataProvider so the pixel buffer's lifetime is tied to the image.
CGImageRef CreateCGImage(const uint8_t *data, size_t length, int width, int height, size_t bytesPerPixel, bool hasAlpha)
{
    CFDataRef cfData = CFDataCreate(kCFAllocatorDefault, data, static_cast<CFIndex>(length));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfData);
    CFRelease(cfData);

    CGColorSpaceRef colorSpace = hasAlpha ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray();
    CGBitmapInfo bitmapInfo = hasAlpha
        ? static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast)
        : static_cast<CGBitmapInfo>(kCGImageAlphaNone);

    CGImageRef image = CGImageCreate(static_cast<size_t>(width), static_cast<size_t>(height), 8,
                                      bytesPerPixel * 8, bytesPerPixel * static_cast<size_t>(width),
                                      colorSpace, bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);

    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    return image;
}

// Premultiplied RGBA8, alpha-last, sized to the layer's own bounds. Nil when there's no color data
// (groups, or a layer psd_sdk couldn't extract channels for).
CGImageRef CreatePixelImage(const psd::Document *document, const psd::Layer *layer)
{
    const int32_t width = layer->right - layer->left;
    const int32_t height = layer->bottom - layer->top;
    if (width <= 0 || height <= 0) {
        return NULL;
    }

    const psd::Channel *r = FindChannel(layer, psd::channelType::R);
    const psd::Channel *g = FindChannel(layer, psd::channelType::G);
    const psd::Channel *b = FindChannel(layer, psd::channelType::B);
    const psd::Channel *a = FindChannel(layer, psd::channelType::TRANSPARENCY_MASK);
    if (!r || !g || !b || !r->data || !g->data || !b->data) {
        return NULL;
    }

    const SampleFn sample = SampleFnForBits(document->bitsPerChannel);
    const size_t pixelCount = static_cast<size_t>(width) * static_cast<size_t>(height);

    const auto *rData = static_cast<const uint8_t *>(r->data);
    const auto *gData = static_cast<const uint8_t *>(g->data);
    const auto *bData = static_cast<const uint8_t *>(b->data);
    const auto *aData = (a && a->data) ? static_cast<const uint8_t *>(a->data) : nullptr;

    std::vector<uint8_t> rgba(pixelCount * 4);
    for (size_t i = 0; i < pixelCount; ++i) {
        const float af = aData ? sample(aData, i) : 1.0f;
        uint8_t *out = &rgba[i * 4];
        out[0] = static_cast<uint8_t>(std::lround(sample(rData, i) * af * 255.0f));
        out[1] = static_cast<uint8_t>(std::lround(sample(gData, i) * af * 255.0f));
        out[2] = static_cast<uint8_t>(std::lround(sample(bData, i) * af * 255.0f));
        out[3] = static_cast<uint8_t>(std::lround(af * 255.0f));
    }

    return CreateCGImage(rgba.data(), rgba.size(), width, height, 4, true);
}

// 8-bit grayscale, no alpha, sized to the mask's own bounds. Nil when the layer has no user mask, or
// psd_sdk never populated its data (layerMask->data stays null unless MoveChannelToMask ran for it).
CGImageRef CreateMaskImage(const psd::Document *document, const psd::Layer *layer)
{
    const psd::LayerMask *mask = layer->layerMask;
    if (!mask || !mask->data) {
        return NULL;
    }

    const int32_t width = mask->right - mask->left;
    const int32_t height = mask->bottom - mask->top;
    if (width <= 0 || height <= 0) {
        return NULL;
    }

    const SampleFn sample = SampleFnForBits(document->bitsPerChannel);
    const size_t pixelCount = static_cast<size_t>(width) * static_cast<size_t>(height);
    const auto *maskData = static_cast<const uint8_t *>(mask->data);

    std::vector<uint8_t> gray(pixelCount);
    for (size_t i = 0; i < pixelCount; ++i) {
        gray[i] = static_cast<uint8_t>(std::lround(sample(maskData, i) * 255.0f));
    }

    return CreateCGImage(gray.data(), gray.size(), width, height, 1, false);
}

NSString *BlendModeString(uint32_t blendModeKey)
{
    const psd::blendMode::Enum mode = psd::blendMode::KeyToEnum(blendModeKey);
    return [NSString stringWithUTF8String:psd::blendMode::ToString(mode)];
}

NSArray<PSDLayerRecord *> *LoadLayerRecords(NSData *fileData, CGSize *canvasSize, NSError **error)
{
    using namespace psd;

    MallocAllocator allocator;
    MemoryFile file(&allocator);
    if (!file.Open(fileData.bytes, fileData.length)) {
        if (error) *error = MakeError(PSDReaderErrorParseFailed);
        return nil;
    }

    Document *document = CreateDocument(&file, &allocator);
    if (!document) {
        file.Close();
        if (error) *error = MakeError(PSDReaderErrorParseFailed);
        return nil;
    }

    if (document->colorMode != colorMode::RGB) {
        DestroyDocument(document, &allocator);
        file.Close();
        if (error) *error = MakeError(PSDReaderErrorUnsupported);
        return nil;
    }

    LayerMaskSection *section = ParseLayerMaskSection(document, &file, &allocator);
    if (!section) {
        DestroyDocument(document, &allocator);
        file.Close();
        if (error) *error = MakeError(PSDReaderErrorParseFailed);
        return nil;
    }

    if (canvasSize) {
        *canvasSize = CGSizeMake(document->width, document->height);
    }

    // Pass 1: assign a stable id to every layer we'll keep, skipping the hidden section-divider
    // bounding layers psd_sdk uses to mark group start/end.
    std::map<const Layer *, NSInteger> layerIDs;
    NSInteger nextID = 0;
    for (unsigned int i = 0; i < section->layerCount; ++i) {
        const Layer *layer = &section->layers[i];
        if (layer->type == layerType::SECTION_DIVIDER) {
            continue;
        }
        layerIDs[layer] = nextID++;
    }

    // Pass 2: extract pixels and build records, resolving each layer's parent via its already-linked
    // `parent` pointer (psd_sdk builds this during parsing, so no manual stack reconstruction needed).
    NSMutableArray<PSDLayerRecord *> *records = [NSMutableArray arrayWithCapacity:layerIDs.size()];
    for (unsigned int i = 0; i < section->layerCount; ++i) {
        Layer *layer = &section->layers[i];
        if (layer->type == layerType::SECTION_DIVIDER) {
            continue;
        }

        ExtractLayer(document, &file, &allocator, layer);

        const bool isGroup = (layer->type == layerType::OPEN_FOLDER) || (layer->type == layerType::CLOSED_FOLDER);

        NSInteger parentID = -1;
        if (layer->parent) {
            const auto it = layerIDs.find(layer->parent);
            if (it != layerIDs.end()) {
                parentID = it->second;
            }
        }

        CGImageRef pixelImage = isGroup ? NULL : CreatePixelImage(document, layer);
        CGImageRef maskImage = isGroup ? NULL : CreateMaskImage(document, layer);
        CGRect maskBounds = CGRectZero;
        if (maskImage) {
            const LayerMask *mask = layer->layerMask;
            maskBounds = CGRectMake(mask->left, mask->top, mask->right - mask->left, mask->bottom - mask->top);
        }

        PSDLayerRecord *record =
            [[PSDLayerRecord alloc] initWithName:[NSString stringWithUTF8String:layer->name.c_str()]
                                          layerID:layerIDs[layer]
                                    parentLayerID:parentID
                                           bounds:CGRectMake(layer->left, layer->top,
                                                              layer->right - layer->left, layer->bottom - layer->top)
                                          isGroup:isGroup
                                          opacity:layer->opacity / 255.0
                                        isVisible:layer->isVisible
                                        blendMode:BlendModeString(layer->blendModeKey)
                                       pixelImage:pixelImage
                                        maskImage:maskImage
                                       maskBounds:maskBounds];
        if (pixelImage) CGImageRelease(pixelImage);
        if (maskImage) CGImageRelease(maskImage);

        [records addObject:record];
    }

    DestroyLayerMaskSection(section, &allocator);
    DestroyDocument(document, &allocator);
    file.Close();

    return records;
}

} // namespace

#pragma mark - PSDDocument

@implementation PSDDocument

+ (nullable NSArray<PSDLayerRecord *> *)layerRecordsWithContentsOfURL:(NSURL *)url
                                                             canvasSize:(nullable CGSize *)canvasSize
                                                                  error:(NSError **)error
{
    NSData *fileData = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!fileData || fileData.length == 0) {
        if (error && !*error) {
            *error = MakeError(PSDReaderErrorParseFailed);
        }
        return nil;
    }

    try {
        NSError *innerError = nil;
        NSArray<PSDLayerRecord *> *records = LoadLayerRecords(fileData, canvasSize, &innerError);
        if (!records && error) {
            *error = innerError ?: MakeError(PSDReaderErrorParseFailed);
        }
        return records;
    } catch (...) {
        if (error) {
            *error = MakeError(PSDReaderErrorParseFailed);
        }
        return nil;
    }
}

@end
