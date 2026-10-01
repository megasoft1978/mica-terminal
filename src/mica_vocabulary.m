#import "mica_vocabulary.h"

#include <sys/wait.h>
#include <ctype.h>
#include <unistd.h>

static NSString *MicaKey(NSString *value) {
    BOOL ascii = YES;
    for (NSUInteger i=0;i<value.length;i++) if ([value characterAtIndex:i] > 0x7f) { ascii=NO; break; }
    if (ascii) {
        NSMutableData *bytes=[NSMutableData dataWithLength:value.length]; uint8_t *out=bytes.mutableBytes; NSUInteger used=0;
        for (NSUInteger i=0;i<value.length;i++) {
            unichar c=[value characterAtIndex:i];
            if (c>='A' && c<='Z') c += ('a'-'A');
            if ((c>='a' && c<='z') || (c>='0' && c<='9')) out[used++]=(uint8_t)c;
        }
        return [[NSString alloc] initWithBytes:out length:used encoding:NSASCIIStringEncoding] ?: @"";
    }
    NSString *folded = ascii ? value.lowercaseString : [[value precomposedStringWithCanonicalMapping]
        stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]].lowercaseString;
    NSMutableString *key = [NSMutableString string];
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar c = [folded characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            (!ascii && [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c])) [key appendFormat:@"%C", c];
    }
    return key;
}

NSArray<NSString *> *MicaVocabularyMerge(NSArray<NSArray<NSString *> *> *sources) {
    NSMutableArray *result = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSArray *source in sources) for (NSString *term in source) {
        if (![term isKindOfClass:NSString.class] || !term.length) continue;
        NSString *key = MicaKey(term); if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key]; [result addObject:term]; if (result.count == 500) return result;
    }
    return result;
}

NSArray<NSString *> *MicaVocabularyTermsFromFile(NSURL *url) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if ([attrs[NSFileSize] unsignedLongLongValue] > 65536) return @[];
    NSString *contents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!contents) return @[];
    NSMutableArray *terms = [NSMutableArray array]; NSUInteger lines = 0;
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (++lines > 1000) break;
        NSString *entry = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!entry.length || [entry hasPrefix:@"#"] || entry.length > 160 || [entry rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) continue;
        NSRange arrow = [entry rangeOfString:@"=>"];
        NSString *left = arrow.location == NSNotFound ? nil : [[entry substringToIndex:arrow.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *right = arrow.location == NSNotFound ? entry : [[entry substringFromIndex:NSMaxRange(arrow)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        // At most one alias delimiter; reject nested/malformed rules instead of interpreting arbitrary input.
        if (!right.length || [right containsString:@"=>"] || (arrow.location != NSNotFound && (!left.length || [left containsString:@"=>"]))) continue;
        [terms addObject:right];
        if (left.length) [terms addObject:[NSString stringWithFormat:@"%@\t%@", left, right]];
    }
    return terms;
}

NSArray<NSString *> *MicaVocabularyTermsFromGitFiles(NSString *directory) {
    if (!directory.length || directory.length > 4096) return @[];
    NSPipe *pipe = [NSPipe pipe]; NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    task.arguments = @[@"-C", directory, @"ls-files", @"-z", @"--cached", @"--", @"."];
    task.standardOutput = pipe; task.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [task launch]; } @catch (__unused NSException *e) { return @[]; }
    NSMutableData *data=[NSMutableData data]; BOOL oversized=NO; NSFileHandle *reader=pipe.fileHandleForReading;
    while (YES) {
        NSData *chunk=[reader readDataOfLength:65536]; if (!chunk.length) break;
        if (data.length + chunk.length > 2 * 1024 * 1024) { oversized=YES; [task terminate]; break; }
        [data appendData:chunk];
    }
    [task waitUntilExit];
    if (oversized || task.terminationStatus != 0) return @[];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; if (!output) return @[];
    NSMutableArray *terms = [NSMutableArray array];
    unichar nulCharacter=0; NSString *nulSeparator=[NSString stringWithCharacters:&nulCharacter length:1];
    for (NSString *path in [output componentsSeparatedByString:nulSeparator]) {
        NSArray<NSString *> *components=path.pathComponents;
        for (NSUInteger i=0;i<components.count;i++) {
            NSString *component=components[i];
            if (i+1==components.count) component=component.stringByDeletingPathExtension;
            component=[component precomposedStringWithCanonicalMapping];
            if (component.length>=4 && [component rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound) [terms addObject:component];
            if (terms.count>=500) break;
        }
        if (terms.count >= 500) break;
    }
    return terms;
}

NSArray<NSString *> *MicaVocabularyTermsFromRecentText(NSString *text, NSDate *capturedAt, NSDate *now) {
    if (!text.length || !capturedAt || [now timeIntervalSinceDate:capturedAt] > 600 || [capturedAt timeIntervalSinceDate:now] > 1) return @[];
    if (text.length > 32768) text = [text substringFromIndex:text.length - 32768];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z_][A-Za-z0-9_]{3,}" options:0 error:nil];
    NSMutableArray *terms = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSString *word = [text substringWithRange:match.range]; NSString *key = MicaKey(word);
        if ([seen containsObject:key]) continue; [seen addObject:key]; [terms addObject:[NSString stringWithFormat:@"@recent\t%@",word]]; if (terms.count == 100) break;
    }
    return terms;
}

static NSUInteger MicaDistance(NSString *a, NSString *b) {
    NSUInteger n = a.length, m = b.length; if (n > 40 || m > 40) return 99;
    NSUInteger d[42][42] = {{0}};
    for (NSUInteger i=0;i<=n;i++) d[i][0]=i; for (NSUInteger j=0;j<=m;j++) d[0][j]=j;
    for (NSUInteger i=1;i<=n;i++) for (NSUInteger j=1;j<=m;j++) {
        NSUInteger cost = [a characterAtIndex:i-1] == [b characterAtIndex:j-1] ? 0 : 1;
        d[i][j]=MIN(MIN(d[i-1][j]+1,d[i][j-1]+1),d[i-1][j-1]+cost);
        if (i>1 && j>1 && [a characterAtIndex:i-1]==[b characterAtIndex:j-2] && [a characterAtIndex:i-2]==[b characterAtIndex:j-1]) d[i][j]=MIN(d[i][j],d[i-2][j-2]+1);
    }
    return d[n][m];
}

static NSString *MicaPhonetic(NSString *key) {
    if (!key.length) return @"";
    NSMutableString *out=[NSMutableString stringWithString:[[key substringToIndex:1] lowercaseString]];
    unichar previous=0;
    for (NSUInteger i=1;i<key.length && out.length<5;i++) {
        unichar c=[[key lowercaseString] characterAtIndex:i]; unichar code=0;
        if ([ @"bfpv" rangeOfString:[NSString stringWithFormat:@"%C",c]].location!=NSNotFound) code='1';
        else if ([ @"cgjkqsxz" rangeOfString:[NSString stringWithFormat:@"%C",c]].location!=NSNotFound) code='2';
        else if ([ @"dt" rangeOfString:[NSString stringWithFormat:@"%C",c]].location!=NSNotFound) code='3';
        else if (c=='l') code='4'; else if ([ @"mn" rangeOfString:[NSString stringWithFormat:@"%C",c]].location!=NSNotFound) code='5'; else if(c=='r') code='6';
        if (code && code!=previous) [out appendFormat:@"%C",code]; previous=code;
    }
    while(out.length<5) [out appendString:@"0"]; return out;
}

NSString *MicaCorrectTranscript(NSString *transcript, NSArray<NSString *> *terms) {
    if (!transcript.length || !terms.count) return transcript ?: @"";
    static NSSet *stop; static dispatch_once_t once; dispatch_once(&once, ^{ stop=[NSSet setWithArray:@[@"this",@"that",@"with",@"from",@"have",@"your",@"just",@"will",@"would",@"could",@"should",@"there",@"their",@"then",@"when",@"what",@"which",@"about",@"into",@"make",@"file",@"test",@"code",@"branch",@"class",@"string",@"array",@"function",@"return",@"error",@"value",@"name",@"path",@"line",@"change",@"build",@"commit",@"project",@"terminal",@"about",@"after",@"again",@"also",@"always",@"another",@"before",@"being",@"below",@"between",@"both",@"check",@"clear",@"could",@"does",@"doing",@"every",@"first",@"found",@"going",@"great",@"hello",@"here",@"large",@"later",@"least",@"leave",@"might",@"never",@"other",@"place",@"point",@"right",@"small",@"still",@"thing",@"think",@"those",@"three",@"under",@"using",@"where",@"while",@"write",@"wrong",@"open",@"close",@"start",@"stop",@"read",@"look",@"need",@"want",@"work",@"done",@"same",@"some",@"many",@"much",@"more",@"most",@"very",@"well",@"word",@"words",@"prompt",@"command",@"common",@"ordinary"]]; });
    NSRegularExpression *word=[NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{N}_]+(?:[-_][\\p{L}\\p{N}_]+)*" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *allMatches=[word matchesInString:transcript options:0 range:NSMakeRange(0,transcript.length)];
    NSMutableSet<NSString *> *initials=[NSMutableSet set];
    for (NSTextCheckingResult *match in allMatches) { NSString *key=MicaKey([transcript substringWithRange:match.range]); if(key.length)[initials addObject:[key substringToIndex:1]]; }
    NSMutableDictionary<NSString *, NSString *> *canonical = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *lowConfidence=[NSMutableSet set];
    NSMutableSet<NSString *> *trustedKeys=[NSMutableSet set];
    NSUInteger used=0;
    for (NSString *term in terms ?: @[]) {
        if (used++ >= 500) break;
        if (![term isKindOfClass:NSString.class] || !term.length) continue;
        unichar first=[term characterAtIndex:0];
        if (first<128 && isalnum((int)first) && ![initials containsObject:[[term substringToIndex:1] lowercaseString]]) {
            NSRange tab=[term rangeOfString:@"\t"];
            NSString *alias=tab.location==NSNotFound ? nil : [term substringToIndex:tab.location];
            unichar aliasFirst=alias.length ? [alias characterAtIndex:0] : 0;
            if (!alias.length || aliasFirst>=128 || !isalnum((int)aliasFirst) || ![initials containsObject:[alias substringToIndex:1].lowercaseString]) continue;
        }
        NSArray *parts=[term componentsSeparatedByString:@"\t"]; NSString *canon=parts.lastObject; NSString *key=MicaKey(canon);
        if (key.length>=4) canonical[key]=canon;
        if (parts.count==2 && [parts[0] isEqualToString:@"@recent"]) { if(key.length>=4)[lowConfidence addObject:key]; }
        else {
            if (key.length>=4) { [trustedKeys addObject:key]; [lowConfidence removeObject:key]; }
            if (parts.count==2) { NSString *alias=MicaKey(parts[0]); if(alias.length) { canonical[alias]=canon; [trustedKeys addObject:alias]; [lowConfidence removeObject:alias]; } }
        }
    }
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byInitial = [NSMutableDictionary dictionary];
    for (NSString *candidate in canonical) {
        NSString *initial=[candidate substringToIndex:1];
        if (!byInitial[initial]) byInitial[initial]=[NSMutableArray array];
        [byInitial[initial] addObject:candidate];
    }
    NSMutableString *result=[transcript mutableCopy];
    NSMutableArray *matches=[NSMutableArray array];
    for (NSInteger i=(NSInteger)allMatches.count-1;i>=0;i--) [matches addObject:allMatches[(NSUInteger)i]];
    NSUInteger rewrites=0;
    for (NSUInteger i=0;i<matches.count;i++) {
        NSTextCheckingResult *match=matches[i];
        if (rewrites>=3) break; NSString *observed=[transcript substringWithRange:match.range]; NSString *key=MicaKey(observed);
        if (!key.length) continue;
        NSString *exact=canonical[key]; if (exact && ![stop containsObject:key] && ![exact isEqualToString:observed]) { [result replaceCharactersInRange:NSMakeRange(match.range.location, observed.length) withString:exact]; rewrites++; continue; }
        // Try up to three adjacent spoken words as one term, preserving any punctuation between them.
        for (NSUInteger span=2;span<=3 && i+span<=matches.count;span++) {
            NSTextCheckingResult *first=matches[i+span-1];
            NSString *piece=[transcript substringWithRange:NSMakeRange(first.range.location, NSMaxRange(match.range)-first.range.location)];
            NSString *spanKey=MicaKey(piece), *spanCanonical=canonical[spanKey];
            if (spanCanonical && ![stop containsObject:spanKey] && ![piece isEqualToString:spanCanonical]) {
                [result replaceCharactersInRange:NSMakeRange(first.range.location, piece.length) withString:spanCanonical]; rewrites++; exact=spanCanonical; break;
            }
        }
        if (exact) continue;
        // Apply the same conservative similarity rule to two- and three-word spoken spans.
        for (NSUInteger span=2;span<=3 && i+span<=matches.count;span++) {
            NSTextCheckingResult *first=matches[i+span-1];
            NSString *piece=[transcript substringWithRange:NSMakeRange(first.range.location, NSMaxRange(match.range)-first.range.location)];
            NSString *spanKey=MicaKey(piece);
            BOOL hasStopword=NO;
            for (NSUInteger part=0;part<span;part++) {
                NSTextCheckingResult *partMatch=matches[i+part];
                if ([stop containsObject:MicaKey([transcript substringWithRange:partMatch.range])]) { hasStopword=YES; break; }
            }
            if (hasStopword || spanKey.length<4) continue;
            NSUInteger spanBest=99, spanRunner=99; NSString *spanWinner=nil;
            for (NSString *candidate in byInitial[[spanKey substringToIndex:1]] ?: @[]) {
                if ([lowConfidence containsObject:candidate] && ![trustedKeys containsObject:candidate]) continue;
                NSUInteger distance=MicaDistance(spanKey,candidate);
                if (distance<spanBest) { spanRunner=spanBest; spanBest=distance; spanWinner=candidate; }
                else if (distance<spanRunner) spanRunner=distance;
            }
            NSUInteger spanThreshold=spanKey.length>=9?2:1;
            if (spanWinner && spanBest<=spanThreshold && spanRunner>spanBest+1 &&
                ![stop containsObject:spanWinner] && [MicaPhonetic(spanWinner) isEqualToString:MicaPhonetic(spanKey)]) {
                [result replaceCharactersInRange:NSMakeRange(first.range.location, piece.length) withString:canonical[spanWinner]];
                rewrites++; exact=canonical[spanWinner]; break;
            }
        }
        if (exact) continue;
        if (key.length<4 || [stop containsObject:key]) continue;
        NSUInteger best=99,runner=99; NSString *winner=nil;
        for (NSString *candidate in byInitial[[key substringToIndex:1]] ?: @[]) {
            if ([lowConfidence containsObject:candidate] && ![trustedKeys containsObject:candidate]) continue;
            NSUInteger dist=MicaDistance(key,candidate); if(dist<best){runner=best;best=dist;winner=candidate;} else if(dist<runner) runner=dist;
        }
        NSUInteger threshold=key.length>=9?2:1;
        if (winner && best<=threshold && runner>best+1 && ![stop containsObject:winner] &&
            [MicaPhonetic(winner) isEqualToString:MicaPhonetic(key)]) {
            NSString *canon=canonical[winner]; [result replaceCharactersInRange:NSMakeRange(match.range.location, observed.length) withString:canon]; rewrites++;
        }
    }
    return result;
}
