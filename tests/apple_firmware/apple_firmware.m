#import <Foundation/Foundation.h>
#import "partial.h"
#import "partial_private.h"

#define ZIP64_OTA_TEST_URL \
    @"https://updates.cdn-apple.com/2023FallFCS/patches/042-82956/83034E50-5068-454B-A3A3-C2BEFD151CA3/com_apple_MobileAsset_MacSoftwareUpdate/3b88e7e7b8d2783611e8ff118a10235e758d46c1.zip"
#define ZIP_OTA_TEST_URL \
    @"https://updates.cdn-apple.com/2023FallFCS/patches/042-75515/E2E5C52E-3F38-4946-82D7-09F96C3E60F3/com_apple_MobileAsset_MacSoftwareUpdate/d434c1c9c4e5fa2fe89aec386c8a160e76de7c71.zip"

#define ZIP64_IPSW_TEST_URL \
    @"https://updates.cdn-apple.com/2024WinterFCS/fullrestores/052-77579/4569734E-120C-4F31-AD08-FC1FF825D059/UniversalMac_14.4.1_23E224_Restore.ipsw"

int test_ota(NSString* url, NSUInteger expected_file_count) {
    NSError* error = nil;

    Partial* zip = [Partial partialZipWithURL:[NSURL URLWithString:url] error:&error];
    if (!zip) {
        NSLog(@"Error: %@", error);
        return 1;
    }
    if (expected_file_count != -1) {
        assert(zip.files.count == expected_file_count);
    }
    assert([zip.files containsObject:@"AssetData/boot/SystemVersion.plist"]);

    // Does not exist
    NSData* nonExistentData = [zip getFileForPath:@"nonexistent" error:&error];
    if (nonExistentData) {
        NSLog(@"Error: Expected nonexistent file to not exist");
        return 1;
    } else {
        error = nil;
    }

    // Folder
    NSData* emptyData = [zip getFileForPath:@"META-INF/" error:&error];
    if (!emptyData) {
        NSLog(@"Error: %@", error);
        return 1;
    } else {
        assert(emptyData.length == 0);
    }

    NSData* data = [zip getFileForPath:@"AssetData/boot/SystemVersion.plist" error:&error];
    if (!data) {
        NSLog(@"Error: %@", error);
        return 1;
    }

    NSDictionary* plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    if (!plist) {
        NSLog(@"Error: %@", error);
        return 1;
    }

    NSDictionary* expected = @ {
        @"BuildID": @"83A728BC-68E7-11EE-9FDF-6497EC07AD66",
        @"ProductBuildVersion": @"22G313",
        @"ProductCopyright": @"1983-2023 Apple Inc.",
        @"ProductName": @"macOS",
        @"ProductUserVisibleVersion": @"13.6.1",
        @"ProductVersion": @"13.6.1",
        @"iOSSupportVersion": @"16.6",
    };

    assert([plist isEqualToDictionary:expected]);

    return 0;
}

int test_ipsw(NSString* url, NSUInteger expected_file_count) {
    NSError* error = nil;

    Partial* zip = [Partial partialZipWithURL:[NSURL URLWithString:url] error:&error];
    if (!zip) {
        NSLog(@"Error: %@", error);
        return 1;
    }
    if (expected_file_count != -1) {
        assert(zip.files.count == expected_file_count);
    }
    assert([zip.files containsObject:@"SystemVersion.plist"]);

    // Does not exist
    NSData* nonExistentData = [zip getFileForPath:@"nonexistent" error:&error];
    if (nonExistentData) {
        NSLog(@"Error: Expected nonexistent file to not exist");
        return 1;
    } else {
        error = nil;
    }

    // Folder
    NSData* emptyData = [zip getFileForPath:@"Firmware/" error:&error];
    if (!emptyData) {
        NSLog(@"Error: %@", error);
        return 1;
    } else {
        assert(emptyData.length == 0);
    }

    NSData* data = [zip getFileForPath:@"SystemVersion.plist" error:&error];
    if (!data) {
        NSLog(@"Error: %@", error);
        return 1;
    }

    NSDictionary* plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    if (!plist) {
        NSLog(@"Error: %@", error);
        return 1;
    }

    NSDictionary* expected = @ {
        @"BuildID": @"BD8B3086-E741-11EE-BB3B-BD0FBDA10519",
        @"ProductBuildVersion": @"23E224",
        @"ProductCopyright": @"1983-2024 Apple Inc.",
        @"ProductName": @"macOS",
        @"ProductUserVisibleVersion": @"14.4.1",
        @"ProductVersion": @"14.4.1",
        @"iOSSupportVersion": @"17.4",
    };

    assert([plist isEqualToDictionary:expected]);

    return 0;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSLog(@"Testing ZIP64 OTA...");
        if (test_ota(ZIP64_OTA_TEST_URL, 2967) != 0) {
            return 1;
        }
        NSLog(@"ZIP64 OTA test passed!");

        NSLog(@"Testing ZIP OTA...");
        if (test_ota(ZIP_OTA_TEST_URL, 49377) != 0) {
            return 1;
        }
        NSLog(@"ZIP OTA test passed!");

        NSLog(@"Testing ZIP64 IPSW...");
        if (test_ipsw(ZIP64_IPSW_TEST_URL, 1327) != 0) {
            return 1;
        }
        NSLog(@"ZIP64 IPSW test passed!");

        NSLog(@"All tests passed!");
    }
    return 0;
}