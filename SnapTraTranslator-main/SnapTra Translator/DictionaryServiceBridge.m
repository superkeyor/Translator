// DictionaryServiceBridge.m
// All private DictionaryServices API calls happen here in Objective-C.
// Uses @try/@catch to safely handle invalid dictionary entries.
// Swift never touches opaque DCSDictionaryRef pointers, avoiding ARC crashes.

#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#include <stdlib.h>
#include <string.h>

// Private DictionaryServices symbols (linked at runtime from CoreServices)
extern CFArrayRef DCSGetActiveDictionaries(void);
extern CFStringRef DCSDictionaryGetName(DCSDictionaryRef dictionary);
extern CFStringRef DCSDictionaryGetShortName(DCSDictionaryRef dictionary);

// Additional private symbols for record-based HTML lookup
extern CFArrayRef DCSCopyRecordsForSearchString(DCSDictionaryRef dictionary,
                                                 CFStringRef string,
                                                 void *u1,
                                                 void *u2);
extern CFStringRef DCSRecordCopyData(CFTypeRef record, long version);

// Cache the array so repeated calls don't re-fetch
static CFArrayRef sCachedDicts = NULL;
static int sCachedCount = 0;

static void sntLoadDicts(void) {
    if (!sCachedDicts) {
        // Use DCSGetActiveDictionaries (returns currently active dicts)
        // instead of DCSCopyAvailableDictionaries (returns all, including broken entries).
        sCachedDicts = DCSGetActiveDictionaries();
        if (sCachedDicts) {
            CFRetain(sCachedDicts); // DCSGet... follows the Get rule (not owned)
        }
        sCachedCount = sCachedDicts ? (int)CFArrayGetCount(sCachedDicts) : 0;
    }
}

int SNTGetDictionaryCount(void) {
    sntLoadDicts();
    return sCachedCount;
}

void SNTRefreshDictionaries(void) {
    if (sCachedDicts) {
        CFRelease(sCachedDicts);
        sCachedDicts = NULL;
    }
    sCachedCount = 0;
    sntLoadDicts();
}

static int cfStringToBuf(CFStringRef cf, char *buf, int bufLen) {
    if (!cf || !buf || bufLen <= 0) return 0;
    if (CFStringGetCString(cf, buf, bufLen, kCFStringEncodingUTF8)) {
        return 1;
    }
    buf[0] = '\0';
    return 0;
}

int SNTGetDictionaryName(int index, char *buf, int bufLen) {
    sntLoadDicts();
    if (!sCachedDicts || index < 0 || index >= sCachedCount || !buf) return 0;
    @try {
        const void *ptr = CFArrayGetValueAtIndex(sCachedDicts, index);
        if (!ptr) return 0;
        DCSDictionaryRef dict = (DCSDictionaryRef)ptr;
        CFStringRef name = DCSDictionaryGetName(dict);
        return cfStringToBuf(name, buf, bufLen);
    } @catch (NSException *e) {
        return 0;
    }
}

int SNTGetDictionaryShortName(int index, char *buf, int bufLen) {
    sntLoadDicts();
    if (!sCachedDicts || index < 0 || index >= sCachedCount || !buf) return 0;
    @try {
        const void *ptr = CFArrayGetValueAtIndex(sCachedDicts, index);
        if (!ptr) return 0;
        DCSDictionaryRef dict = (DCSDictionaryRef)ptr;
        CFStringRef sn = DCSDictionaryGetShortName(dict);
        return cfStringToBuf(sn, buf, bufLen);
    } @catch (NSException *e) {
        return 0;
    }
}

char *SNTCopyDefinition(int index, const char *word) {
    sntLoadDicts();
    if (!sCachedDicts || index < 0 || index >= sCachedCount || !word) return NULL;
    @try {
        const void *ptr = CFArrayGetValueAtIndex(sCachedDicts, index);
        if (!ptr) return NULL;
        DCSDictionaryRef dict = (DCSDictionaryRef)ptr;
        CFStringRef cfWord = CFStringCreateWithCString(NULL, word, kCFStringEncodingUTF8);
        if (!cfWord) return NULL;
        CFRange range = CFRangeMake(0, CFStringGetLength(cfWord));
        CFStringRef def = DCSCopyTextDefinition(dict, cfWord, range);
        CFRelease(cfWord);
        if (!def) return NULL;
        CFIndex len = CFStringGetMaximumSizeForEncoding(CFStringGetLength(def), kCFStringEncodingUTF8) + 1;
        char *result = malloc((size_t)len);
        if (result) {
            if (!CFStringGetCString(def, result, len, kCFStringEncodingUTF8)) {
                free(result);
                result = NULL;
            }
        }
        CFRelease(def);
        return result;
    } @catch (NSException *e) {
        return NULL;
    }
}

char *SNTCopyDefaultDefinition(const char *word) {
    if (!word) return NULL;
    @try {
        CFStringRef cfWord = CFStringCreateWithCString(NULL, word, kCFStringEncodingUTF8);
        if (!cfWord) return NULL;
        CFRange range = CFRangeMake(0, CFStringGetLength(cfWord));
        CFStringRef def = DCSCopyTextDefinition(NULL, cfWord, range);
        CFRelease(cfWord);
        if (!def) return NULL;
        CFIndex len = CFStringGetMaximumSizeForEncoding(CFStringGetLength(def), kCFStringEncodingUTF8) + 1;
        char *result = malloc((size_t)len);
        if (result) {
            if (!CFStringGetCString(def, result, len, kCFStringEncodingUTF8)) {
                free(result);
                result = NULL;
            }
        }
        CFRelease(def);
        return result;
    } @catch (NSException *e) {
        return NULL;
    }
}

// Record-based HTML lookup using DCSCopyRecordsForSearchString + DCSRecordCopyData.
// version: 0 = raw HTML, 1 = HTML with app CSS, 2 = HTML with popover CSS, 3 = plain text
char *SNTCopyHTMLDefinition(int index, const char *word, int version) {
    sntLoadDicts();
    if (!sCachedDicts || index < 0 || index >= sCachedCount || !word) return NULL;
    @try {
        const void *ptr = CFArrayGetValueAtIndex(sCachedDicts, index);
        if (!ptr) return NULL;
        DCSDictionaryRef dict = (DCSDictionaryRef)ptr;
        CFStringRef cfWord = CFStringCreateWithCString(NULL, word, kCFStringEncodingUTF8);
        if (!cfWord) return NULL;

        CFArrayRef records = DCSCopyRecordsForSearchString(dict, cfWord, NULL, NULL);
        CFRelease(cfWord);
        if (!records) return NULL;

        CFIndex count = CFArrayGetCount(records);
        if (count == 0) {
            CFRelease(records);
            return NULL;
        }

        // Collect HTML from all records
        NSMutableString *combined = [NSMutableString string];
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef record = CFArrayGetValueAtIndex(records, i);
            if (!record) continue;
            CFStringRef data = DCSRecordCopyData(record, (long)version);
            if (data) {
                if ([combined length] > 0) {
                    [combined appendString:@"\n<hr class=\"snt-separator\">\n"];
                }
                [combined appendString:(__bridge NSString *)data];
                CFRelease(data);
            }
        }
        CFRelease(records);

        if ([combined length] == 0) return NULL;

        CFIndex len = [combined maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
        char *result = malloc((size_t)len);
        if (result) {
            if (![combined getCString:result maxLength:(NSUInteger)len encoding:NSUTF8StringEncoding]) {
                free(result);
                result = NULL;
            }
        }
        return result;
    } @catch (NSException *e) {
        return NULL;
    }
}
