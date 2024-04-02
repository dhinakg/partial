//
//  partial_private.h
//  partial
//
//  Created by Dhinak G on 3/27/24.
//

#ifndef partial_private_h
#define partial_private_h

#import <stdint.h>
#import "partial.h"

#ifdef DEBUG
#define log(fmt, ...) NSLog(@"partial: " fmt, ##__VA_ARGS__)
#else
#define log(fmt, ...)
#endif

#define MAIN_ERROR_DOMAIN @"libpartial"

#define err(fmt, ...) \
    [NSError errorWithDomain:MAIN_ERROR_DOMAIN code:0 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:fmt, ##__VA_ARGS__]}]
#define err_with_underlying(underlying, fmt, ...) \
    [NSError                                      \
        errorWithDomain:MAIN_ERROR_DOMAIN         \
                   code:0                         \
               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:fmt, ##__VA_ARGS__], NSUnderlyingErrorKey: underlying}]

// TODO: Option for a greedy approach
// - Assume the only extra field is zip, so fetch header, max zip64 extra field size, and compressed size
// - Maybe fetch bigger chunks of the end
// - Have some kind of way to ensure that we don't repeat requests

// TODO: Endianess (assumes host is little-endian currently)

#define OFFSET_FROM_END(offset) NSMakeRange(self->_size - (offset), (offset))

#define ZIP_PACKED __attribute__((__packed__))

// TODO: Turn signatures into enums

typedef struct ZIP_PACKED zip_end_of_central_directory {
    uint32_t signature;
    uint16_t disk_number;
    uint16_t disk_with_cd;
    uint16_t cd_records_on_disk;
    uint16_t cd_records;
    uint32_t cd_size;
    uint32_t cd_offset;
    uint16_t comment_length;
} zip_end_of_central_directory;

static_assert(sizeof(zip_end_of_central_directory) == 22, "zip_end_of_central_directory size mismatch");

#define ZIP_END_OF_CENTRAL_DIRECTORY_SIGNATURE 0x06054B50U

typedef struct ZIP_PACKED zip64_end_of_central_directory_locator {
    uint32_t signature;
    uint32_t disk_with_eocd;
    uint64_t eocd_offset;
    uint32_t total_disks;
} zip64_end_of_central_directory_locator;

static_assert(sizeof(zip64_end_of_central_directory_locator) == 20, "zip64_end_of_central_directory_locator size mismatch");

#define ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE 0x07064b50U

typedef struct ZIP_PACKED zip64_end_of_central_directory {
    uint32_t signature;
    uint64_t size;
    uint16_t version;
    uint16_t version_needed;
    uint32_t disk_number;
    uint32_t disk_with_cd;
    uint64_t cd_records_on_disk;
    uint64_t cd_records;
    uint64_t cd_size;
    uint64_t cd_offset;
} zip64_end_of_central_directory;

static_assert(sizeof(zip64_end_of_central_directory) == 56, "zip64_end_of_central_directory size mismatch");

#define ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE 0x06064b50U

typedef enum zip_general_flags : uint16_t {
    ZIP_FLAG_ENCRYPTED = 1 << 0,
    ZIP_FLAG_DATA_DESCRIPTOR = 1 << 3,
} zip_general_flags;

typedef enum zip_compression_method : uint16_t {
    ZIP_COMPRESSION_METHOD_STORE = 0,
    ZIP_COMPRESSION_METHOD_DEFLATE = 8,
} zip_compression_method;

typedef struct ZIP_PACKED zip_central_directory_file_header {
    uint32_t signature;
    uint16_t version_made_by;
    uint16_t version_needed;
    zip_general_flags flags;
    zip_compression_method compression;
    uint16_t mod_time;
    uint16_t mod_date;
    uint32_t crc32;
    uint32_t compressed_size;
    uint32_t uncompressed_size;
    uint16_t file_name_length;
    uint16_t extra_field_length;
    uint16_t file_comment_length;
    uint16_t disk_number_start;
    uint16_t internal_file_attributes;
    uint32_t external_file_attributes;
    uint32_t local_header_offset;
} zip_central_directory_file_header;

static_assert(sizeof(zip_central_directory_file_header) == 46, "zip_central_directory_file_header size mismatch");

#define ZIP_CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE 0x02014B50U

// TODO: Figure out CP437 vs UTF-8
static inline NSString* zip_file_name(zip_central_directory_file_header* file_header) {
    return [[NSString alloc] initWithBytes:(char*)((uintptr_t)file_header + sizeof(zip_central_directory_file_header))
                                    length:file_header->file_name_length
                                  encoding:NSUTF8StringEncoding];
}

typedef struct ZIP_PACKED zip_extra_field {
    uint16_t header_id;
    uint16_t data_size;
} zip_extra_field;

static_assert(sizeof(zip_extra_field) == 4, "zip_extra_field size mismatch");

typedef struct ZIP_PACKED zip_extra_field_zip64 {
    uint16_t header_id;
    uint16_t data_size;
    uint64_t uncompressed_size;
    uint64_t compressed_size;
    uint64_t local_header_offset;
    uint32_t disk_number_start;
} zip_extra_field_zip64;

static_assert(sizeof(zip_extra_field_zip64) == 32, "zip_extra_field_zip64 size mismatch");

#define ZIP_EXTRA_FIELD_ZIP64_HEADER_ID 0x0001U

// #define zip_file_name(file_header) (char *)((uintptr_t)file_header + sizeof(zip_central_directory_file_header))

#define zip_first_extra_field(file_header) \
    (zip_extra_field*)((uintptr_t)file_header + sizeof(zip_central_directory_file_header) + file_header->file_name_length)

#define zip_next_extra_field(extra_field) (zip_extra_field*)((uintptr_t)extra_field + sizeof(zip_extra_field) + extra_field->data_size)

// #define zip_file_comment(file_header)                                                                             \
//     (char *)((uintptr_t)file_header + sizeof(zip_central_directory_file_header) + file_header->file_name_length + \
//              file_header->extra_field_length)
#define zip_next_file_header(file_header)                                                                     \
    (zip_central_directory_file_header*)((uintptr_t)file_header + sizeof(zip_central_directory_file_header) + \
                                         file_header->file_name_length + file_header->extra_field_length +    \
                                         file_header->file_comment_length)

typedef struct ZIP_PACKED zip_local_file_header {
    uint32_t signature;
    uint16_t version_needed;
    uint16_t flags;
    uint16_t compression;
    uint16_t mod_time;
    uint16_t mod_date;
    uint32_t crc32;
    uint32_t compressed_size;
    uint32_t uncompressed_size;
    uint16_t file_name_length;
    uint16_t extra_field_length;
} zip_local_file_header;

static_assert(sizeof(zip_local_file_header) == 30, "zip_local_file_header size mismatch");

#define ZIP_LOCAL_FILE_HEADER_SIGNATURE 0x04034B50U

typedef struct zip64_adjusted_fields {
    uint64_t uncompressed_size;
    uint64_t compressed_size;
    uint64_t local_header_offset;
    uint32_t disk_number_start;
} zip64_adjusted_fields;

@interface Partial (Private)

- (NSError*)_getMetadata;
- (NSError*)_fetchEndOfCentralDirectory;
- (NSError*)_fetchCentralDirectory;
- (zip_central_directory_file_header*)_fetchFileHeader:(NSString*)fileName;
- (NSData*)_fetchCompressedFile:(zip_central_directory_file_header*)fileHeader error:(NSError**)error;
- (NSData*)_decompressFile:(NSData*)compressedData fileHeader:(zip_central_directory_file_header*)fileHeader error:(NSError**)error;

@end

@interface NSValue (ZipCentralDirectoryFileHeader)
+ (NSValue*)valueWithZipCentralDirectoryFileHeader:(zip_central_directory_file_header*)fileHeader;
@property(readonly) zip_central_directory_file_header* zipCentralDirectoryFileHeaderValue;

@end

@interface PartialOrderedMutableDictionary<KeyType, ObjectType> : NSMutableDictionary <KeyType, ObjectType> {
    NSMutableDictionary<KeyType, ObjectType>* _dictionary;
    NSMutableArray<KeyType>* _orderedKeys;
}
@end

#endif /* partial_private_h */
