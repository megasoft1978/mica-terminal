#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *MicaCorrectTranscript(NSString *transcript, NSArray<NSString *> *terms);
FOUNDATION_EXPORT NSURL * _Nullable MicaGitExecutableURL(void);
FOUNDATION_EXPORT NSArray<NSString *> *MicaVocabularyTermsFromFile(NSURL *url);
FOUNDATION_EXPORT NSArray<NSString *> *MicaVocabularyTermsFromGitFiles(NSString *directory);
FOUNDATION_EXPORT NSArray<NSString *> *MicaVocabularyTermsFromRecentText(NSString *text, NSDate *capturedAt, NSDate *now);
FOUNDATION_EXPORT NSArray<NSString *> *MicaVocabularyMerge(NSArray<NSArray<NSString *> *> *sources);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *MicaDictationSnippetsFromFile(NSURL *url);
FOUNDATION_EXPORT NSString *MicaApplyDictationSnippet(NSString *transcript, NSDictionary<NSString *, NSString *> *snippets);
