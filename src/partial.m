//
//  partial.m
//  partial
//
//  Created by Dhinak G on 3/4/24.
//

#import "partial.h"
#import <Foundation/Foundation.h>
#import <zlib.h>
#import "partial_private.h"

@implementation NSValue (ZipCentralDirectoryFileHeader)
+ (NSValue*)valueWithZipCentralDirectoryFileHeader:(zip_central_directory_file_header*)fileHeader {
    return [self valueWithPointer:fileHeader];
}
- (zip_central_directory_file_header*)zipCentralDirectoryFileHeaderValue {
    zip_central_directory_file_header* fileHeader;
    [self getValue:&fileHeader];
    return fileHeader;
}
@end

@implementation Partial

- (instancetype)initWithURL:(NSURL*)url error:(NSError**)error {
    if (self = [super init]) {
        self->_url = url;
        self->_session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];

        NSError* _error = [self _getMetadata];
        if (!_error) {
            _error = [self _fetchEndOfCentralDirectory];
        }
        if (!_error) {
            _error = [self _fetchCentralDirectory];
        }

        if (_error) {
            if (error) {
                *error = _error;
            }
            return nil;
        }
    }
    return self;
}

+ (instancetype)partialZipWithURL:(NSURL*)url error:(NSError**)error {
    return [[self alloc] initWithURL:url error:error];
}

- (NSData*)_makeSynchronousRequest:(NSURLRequest*)request returningResponse:(NSHTTPURLResponse**)response error:(NSError**)error {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData* data = nil;
    __block NSHTTPURLResponse* taskResponse = nil;
    __block NSError* taskError = nil;

    NSURLSessionDataTask* task = [self->_session dataTaskWithRequest:request
                                                   completionHandler:^(NSData* taskData, NSURLResponse* response, NSError* error) {
                                                       data = taskData;

                                                       if (response) {
                                                           assert([response isKindOfClass:[NSHTTPURLResponse class]]);
                                                       }
                                                       taskResponse = (NSHTTPURLResponse*)response;

                                                       taskError = error;
                                                       dispatch_semaphore_signal(semaphore);
                                                   }];
    [task resume];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (response) {
        *response = taskResponse;
    }

    if (error) {
        *error = taskError;
    }

    return data;
}

- (NSData*)_getBytesInRange:(NSRange)range error:(NSError**)error {
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:self->_url];
    [request setValue:[NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)range.location, (unsigned long)NSMaxRange(range) - 1]
        forHTTPHeaderField:@"Range"];

    NSHTTPURLResponse* response = nil;
    NSData* data = [self _makeSynchronousRequest:request returningResponse:&response error:error];
    if (!data) {
        return nil;
    }

    if (response.statusCode != 206) {
        log(@"Server did not return a 206 status code!");
        if (error) {
            *error = err(@"Server did not return a 206 status code! Got %ld", (long)response.statusCode);
        }
        return nil;
    }

    log(@"Response headers: %@", response.allHeaderFields);

    return data;
}

- (NSError*)_getMetadata {
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:self->_url];
    request.HTTPMethod = @"HEAD";

    NSHTTPURLResponse* response = nil;
    NSError* error = nil;
    [self _makeSynchronousRequest:request returningResponse:&response error:&error];
    if (error) {
        log(@"Error: %@", error);
        return err_with_underlying(error, @"Failed to fetch file metadata!");
    }

    if (response.statusCode != 200) {
        log(@"Server did not return a 200 status code!");
        return err(@"Server did not return a 200 status code!");
    }

    // Check for range support
    NSString* range = [response valueForHTTPHeaderField:@"Accept-Ranges"];
    if (![range isEqualToString:@"bytes"]) {
        log(@"Server does not support range requests!");
        return err(@"Server does not support range requests!");
    }

    self->_size = response.expectedContentLength;
    if (self->_size == NSURLResponseUnknownLength) {
        log(@"Size is unknown!");
        return err(@"Size is unknown!");
    }

    if (self->_size == 0) {
        log(@"Size is zero!");
        return err(@"Size is zero!");
    }

    return nil;
}

// TODO: Account for comments (use sliding window to find the end of central directory signature)
// https://stackoverflow.com/a/4802703

- (NSError*)_fetchEndOfCentralDirectory {
    NSError* error = nil;

    // Fetch the end of central directory, as well as the 20 bytes preceding it. If this is a ZIP64 file, the ZIP64 end of central
    // directory locator should immediately precede the end of central directory.
    // TODO: Check that the zip file is large enough
    NSRange range = OFFSET_FROM_END(sizeof(zip_end_of_central_directory) + sizeof(zip64_end_of_central_directory_locator));
    NSData* data = [self _getBytesInRange:range error:&error];
    if (!data) {
        return error;
    }

    self->_endOfCentralDirectory = malloc(sizeof(zip_end_of_central_directory));
    [data getBytes:self->_endOfCentralDirectory
             range:NSMakeRange(data.length - sizeof(zip_end_of_central_directory), sizeof(zip_end_of_central_directory))];
    if (self->_endOfCentralDirectory->signature != ZIP_END_OF_CENTRAL_DIRECTORY_SIGNATURE) {
        log(@"End of central directory signature is invalid!");
        log(@"Signature: %x", self->_endOfCentralDirectory->signature);
        log(@"Expected: %x", ZIP_END_OF_CENTRAL_DIRECTORY_SIGNATURE);
        return err(@"End of central directory signature is invalid! Expected %x, got %x", ZIP_END_OF_CENTRAL_DIRECTORY_SIGNATURE,
                   self->_endOfCentralDirectory->signature);
    }

    if (((zip64_end_of_central_directory_locator*)data.bytes)->signature == ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE) {
        log(@"ZIP64 end of central directory locator found!");
        self->_isZip64 = true;
        // Directly overlay zip64_end_of_central_directory_locator on top of the NSData bytes, as we don't need this after we locate the
        // ZIP64 end of central directory
        zip64_end_of_central_directory_locator* locator = (zip64_end_of_central_directory_locator*)data.bytes;
        if (locator->signature != ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE) {
            log(@"ZIP64 end of central directory locator signature is invalid!");
            log(@"Signature: %x", locator->signature);
            log(@"Expected: %x", ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE);
            return err(@"ZIP64 end of central directory locator signature is invalid! Expected %x, got %x",
                       ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR_SIGNATURE, locator->signature);
        }

        // Fetch the ZIP64 end of central directory
        NSRange zip64Range = NSMakeRange(locator->eocd_offset, sizeof(zip64_end_of_central_directory));
        NSData* zip64Data = [self _getBytesInRange:zip64Range error:&error];
        if (!zip64Data) {
            return error;
        }

        self->_endOfCentralDirectory64 = malloc(sizeof(zip64_end_of_central_directory));
        [zip64Data getBytes:self->_endOfCentralDirectory64 length:sizeof(zip64_end_of_central_directory)];
        if (self->_endOfCentralDirectory64->signature != ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE) {
            log(@"ZIP64 end of central directory signature is invalid!");
            log(@"Signature: %x", self->_endOfCentralDirectory64->signature);
            log(@"Expected: %x", ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE);
            return err(@"ZIP64 end of central directory signature is invalid! Expected %x, got %x",
                       ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE, self->_endOfCentralDirectory64->signature);
        }
    }

    return nil;
}

// TODO: There's probably some edge cases with duplicate file names or case sensitivity

- (NSError*)_fetchCentralDirectory {
    NSError* error = nil;

    NSRange range;
    if (self->_isZip64) {
        range = NSMakeRange(self->_endOfCentralDirectory64->cd_offset, self->_endOfCentralDirectory64->cd_size);
        self->_centralDirectoryCount = self->_endOfCentralDirectory64->cd_records;
    } else {
        range = NSMakeRange(self->_endOfCentralDirectory->cd_offset, self->_endOfCentralDirectory->cd_size);
        self->_centralDirectoryCount = self->_endOfCentralDirectory->cd_records;
    }

    NSData* data = [self _getBytesInRange:range error:&error];
    if (!data) {
        return error;
    }

    self->_centralDirectory = malloc(range.length);
    [data getBytes:self->_centralDirectory length:range.length];

    self->_fileHeaders = [[NSMutableDictionary alloc] initWithCapacity:self->_centralDirectoryCount];

    zip_central_directory_file_header* current = &self->_centralDirectory[0];
    for (int i = 0; i < self->_centralDirectoryCount; i++) {
        if (current->signature != ZIP_CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE) {
            log(@"Central directory signature is invalid!");
            log(@"Signature: %x", current->signature);
            log(@"Expected: %x", ZIP_CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE);
            return err(@"Central directory signature is invalid! Expected %x, got %x", ZIP_CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE,
                       current->signature);
        }

        log(@"File name: %@ (%p)", zip_file_name(current), current);

        self->_fileHeaders[zip_file_name(current)] = [NSValue valueWithZipCentralDirectoryFileHeader:current];

        current = zip_next_file_header(current);
    }

    return nil;
}

- (NSArray<NSString*>*)files {
    return self->_fileHeaders.allKeys;
}

- (zip_central_directory_file_header*)_fetchFileHeader:(NSString*)fileName {
    NSValue* value = self->_fileHeaders[fileName];
    return value ? value.zipCentralDirectoryFileHeaderValue : nil;
}

- (NSError*)_processZip64:(zip_central_directory_file_header*)fileHeader adjustedFields:(zip64_adjusted_fields*)adjusted {
    // Note: The ZIP64 extra field has uncompressed/compressed in a different order from the central directory and local headers
    uint64_t uncompressedSize = fileHeader->uncompressed_size;
    uint64_t compressedSize = fileHeader->compressed_size;
    uint64_t localHeaderOffset = fileHeader->local_header_offset;
    // We process this even though we don't need it as it simplifies the ZIP64 handling
    uint32_t diskNumberStart = fileHeader->disk_number_start;
    log(@"Uncompressed size: %llu", uncompressedSize);
    log(@"Compressed size: %llu", compressedSize);
    log(@"Local header offset: %llu", localHeaderOffset);
    log(@"Disk number start: %u", diskNumberStart);

    if (self->_isZip64 && (compressedSize == UINT32_MAX || uncompressedSize == UINT32_MAX || localHeaderOffset == UINT32_MAX ||
                           diskNumberStart == UINT16_MAX)) {
        if (fileHeader->extra_field_length < sizeof(zip_extra_field)) {
            log(@"Extra field size is too small! (%u)", fileHeader->extra_field_length);
            return err(@"Extra field size is too small! Expected at least %lu, got %u", sizeof(zip_extra_field),
                       fileHeader->extra_field_length);
        }

        int requiredZip64ExtraFieldSize = 0;
        if (uncompressedSize == UINT32_MAX) {
            requiredZip64ExtraFieldSize += sizeof(uint64_t);
        }
        if (compressedSize == UINT32_MAX) {
            requiredZip64ExtraFieldSize += sizeof(uint64_t);
        }
        if (localHeaderOffset == UINT32_MAX) {
            requiredZip64ExtraFieldSize += sizeof(uint64_t);
        }
        if (diskNumberStart == UINT16_MAX) {
            requiredZip64ExtraFieldSize += sizeof(uint32_t);
        }

        zip_extra_field* end = zip_first_extra_field(fileHeader) + fileHeader->extra_field_length;
        zip_extra_field* current = zip_first_extra_field(fileHeader);

        while (current < end) {
            if (current->data_size + sizeof(zip_extra_field) > end - current) {
                log(@"Extra field size is too large!");
                return err(@"Extra field size is too large! Expected at most %lu, got %u", end - current, current->data_size);
            }
            if (current->header_id == ZIP_EXTRA_FIELD_ZIP64_HEADER_ID) {
                zip_extra_field_zip64* zip64ExtraField = (zip_extra_field_zip64*)current;
                log(@"ZIP64 extra field size: %u", zip64ExtraField->data_size);
                if (zip64ExtraField->data_size != requiredZip64ExtraFieldSize) {
                    log(@"ZIP64 extra field size is invalid!");
                    return err(@"ZIP64 extra field size is invalid! Expected %d, got %u", requiredZip64ExtraFieldSize,
                               zip64ExtraField->data_size);
                }

                char* currentField = (char*)zip64ExtraField + sizeof(zip_extra_field);

                if (uncompressedSize == UINT32_MAX) {
                    uncompressedSize = *(uint64_t*)currentField;
                    log(@"New uncompressed size: %llu", uncompressedSize);
                    currentField += sizeof(uint64_t);
                }

                if (compressedSize == UINT32_MAX) {
                    compressedSize = *(uint64_t*)currentField;
                    log(@"New compressed size: %llu", compressedSize);
                    currentField += sizeof(uint64_t);
                }

                if (localHeaderOffset == UINT32_MAX) {
                    localHeaderOffset = *(uint64_t*)currentField;
                    log(@"New local header offset: %llu", localHeaderOffset);
                    currentField += sizeof(uint64_t);
                }

                if (diskNumberStart == UINT16_MAX) {
                    diskNumberStart = *(uint32_t*)currentField;
                    log(@"New disk number start: %u", diskNumberStart);
                    currentField += sizeof(uint32_t);
                }

                break;
            }

            current = zip_next_extra_field(current);
        }

        if (current == end) {
            log(@"ZIP64 extra field not found!");
            return err(@"ZIP64 extra field not found!");
        }
    }

    adjusted->uncompressed_size = uncompressedSize;
    adjusted->compressed_size = compressedSize;
    adjusted->local_header_offset = localHeaderOffset;
    adjusted->disk_number_start = diskNumberStart;

    return nil;
}

// TODO: Stream to file or something for large files
// TODO: Do we trust central directory or local file header? Pick one and establish it
- (NSData*)_fetchCompressedFile:(zip_central_directory_file_header*)fileHeader error:(NSError**)error {
    if (fileHeader->flags & ZIP_FLAG_ENCRYPTED) {
        log(@"File is encrypted!");
        if (error) {
            *error = err(@"File is encrypted!");
        }
        return nil;
    }

    if (fileHeader->flags & ZIP_FLAG_DATA_DESCRIPTOR) {
        // TODO: Data descriptor support
        log(@"File uses a data descriptor!");
        if (error) {
            *error = err(@"File uses a data descriptor!");
        }
        return nil;
    }

    zip64_adjusted_fields adjusted;
    NSError* zip64Error = [self _processZip64:fileHeader adjustedFields:&adjusted];
    if (zip64Error) {
        if (error) {
            *error = zip64Error;
        }
        return nil;
    }

    NSRange range = NSMakeRange(adjusted.local_header_offset, sizeof(zip_local_file_header));
    NSData* data = [self _getBytesInRange:range error:error];
    if (!data) {
        return nil;
    }

    // Directly overlay zip_local_file_header on top of the NSData bytes, as we don't need this after we grab the compressed bytes
    zip_local_file_header* localHeader = (zip_local_file_header*)data.bytes;
    if (localHeader->signature != ZIP_LOCAL_FILE_HEADER_SIGNATURE) {
        log(@"Local file header signature is invalid!");
        log(@"Signature: %x", localHeader->signature);
        log(@"Expected: %x", ZIP_LOCAL_FILE_HEADER_SIGNATURE);
        if (error) {
            *error = err(@"Local file header signature is invalid! Expected %x, got %x", ZIP_LOCAL_FILE_HEADER_SIGNATURE,
                         localHeader->signature);
        }
        return nil;
    }

    NSRange compressedFileRange = NSMakeRange(
        adjusted.local_header_offset + sizeof(zip_local_file_header) + localHeader->file_name_length + localHeader->extra_field_length,
        adjusted.compressed_size);
    log(@"Compressed file range: %@", NSStringFromRange(compressedFileRange));
    log(@"Compressed file range: loc: %lu, len: %lu", (unsigned long)compressedFileRange.location,
        (unsigned long)compressedFileRange.length);

    if (compressedFileRange.length == 0) {
        // Empty file, don't attempt to fetch, just return empty NSData
        return [NSData data];
    }

    NSData* compressedFileData = [self _getBytesInRange:compressedFileRange error:error];
    if (!compressedFileData) {
        log(@"Failed to fetch compressed file data!");
        return nil;
    }

    return compressedFileData;
}

- (NSData*)_decompressFile:(NSData*)compressedData fileHeader:(zip_central_directory_file_header*)fileHeader error:(NSError**)error {
    zip64_adjusted_fields adjusted;
    NSError* zip64Error = [self _processZip64:fileHeader adjustedFields:&adjusted];
    if (zip64Error) {
        if (error) {
            *error = zip64Error;
        }
        return nil;
    }

    NSMutableData* decompressedData = [NSMutableData dataWithLength:adjusted.uncompressed_size];

    switch (fileHeader->compression) {
        case ZIP_COMPRESSION_METHOD_STORE:
            if (adjusted.compressed_size != adjusted.uncompressed_size) {
                log(@"Stored file has different compressed and uncompressed sizes!");
                if (error) {
                    *error = err(@"Stored file has different compressed and uncompressed sizes! %llu != %llu", adjusted.compressed_size,
                                 adjusted.uncompressed_size);
                }
                return nil;
            }
            decompressedData = [compressedData mutableCopy];
            break;
        case ZIP_COMPRESSION_METHOD_DEFLATE: {
            // return [compressedData decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:error];
            z_stream stream = {0};
            inflateInit2(&stream, -MAX_WBITS);
            stream.next_in = (Bytef*)compressedData.bytes;
            stream.avail_in = (uInt)compressedData.length;
            stream.next_out = (Bytef*)decompressedData.mutableBytes;
            stream.avail_out = (uInt)decompressedData.length;

            int status = inflate(&stream, Z_FINISH);
            if (status != Z_STREAM_END) {
                log(@"Failed to decompress data!");
                if (error) {
                    *error = err(@"Failed to decompress data! zlib error: %d", status);
                }
                return nil;
            }
            inflateEnd(&stream);
            break;
        }

        default:
            log(@"Unsupported compression method!");
            if (error) {
                *error = err(@"Unsupported compression method! %u", fileHeader->compression);
            }
            return nil;
    }

    if (decompressedData.length != adjusted.uncompressed_size) {
        log(@"Decompressed data size does not match uncompressed size!");
        if (error) {
            *error = err(@"Decompressed data size does not match uncompressed size! %lu != %llu", decompressedData.length,
                         adjusted.uncompressed_size);
        }
        return nil;
    }

    return decompressedData;
}

- (NSData*)getFileForPath:(NSString*)path error:(NSError* __autoreleasing _Nullable*)error {
    zip_central_directory_file_header* fileHeader = [self _fetchFileHeader:path];
    if (!fileHeader) {
        log(@"Failed to fetch file header!");
        if (error) {
            *error = err(@"File %@ does not exist!", path);
        }
        return nil;
    }

    NSData* compressedData = [self _fetchCompressedFile:fileHeader error:error];
    if (!compressedData) {
        return nil;
    }

    NSData* decompressedData = [self _decompressFile:compressedData fileHeader:fileHeader error:error];
    if (!decompressedData) {
        return nil;
    }

    return decompressedData;
}

- (void)dealloc {
    if (self->_endOfCentralDirectory) {
        free(self->_endOfCentralDirectory);
    }
    if (self->_endOfCentralDirectory64) {
        free(self->_endOfCentralDirectory64);
    }
    if (self->_centralDirectory) {
        free(self->_centralDirectory);
    }
}

@end