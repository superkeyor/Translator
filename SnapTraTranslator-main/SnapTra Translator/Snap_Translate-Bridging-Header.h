//
//  Snap_Translate-Bridging-Header.h
//  Snap Translate
//

#ifndef Snap_Translate_Bridging_Header_h
#define Snap_Translate_Bridging_Header_h

#import <CoreServices/CoreServices.h>

// Private DictionaryServices API wrappers.
// All private API calls happen in C to avoid Swift ARC crashing on opaque CF pointers.

/// Returns the number of installed dictionaries.
int SNTGetDictionaryCount(void);

/// Invalidate the cached dictionary list and re-fetch from the system.
void SNTRefreshDictionaries(void);

/// Copy the name of the dictionary at the given index into buf.
/// Returns 1 on success, 0 on failure.
int SNTGetDictionaryName(int index, char *buf, int bufLen);

/// Copy the short name of the dictionary at the given index into buf.
/// Returns 1 on success, 0 on failure.
int SNTGetDictionaryShortName(int index, char *buf, int bufLen);

/// Look up a word in the dictionary at the given index.
/// Returns a malloc'd C string (caller must free) or NULL.
char * _Nullable SNTCopyDefinition(int index, const char *word);

/// Look up a word using the default dictionary.
/// Returns a malloc'd C string (caller must free) or NULL.
char * _Nullable SNTCopyDefaultDefinition(const char *word);

/// Look up a word in the dictionary at the given index and return HTML.
/// version: 0 = raw HTML, 1 = HTML with app CSS, 2 = HTML with popover CSS, 3 = plain text.
/// Returns a malloc'd C string (caller must free) or NULL.
char * _Nullable SNTCopyHTMLDefinition(int index, const char *word, int version);

#endif
